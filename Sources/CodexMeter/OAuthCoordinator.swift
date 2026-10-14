import AuthenticationServices
import CryptoKit
import Foundation
import Network
import Security
import UIKit
import CodexMeterCore

enum SignInMethod {
    case browser
    case deviceCode
}

@MainActor
final class OAuthCoordinator: NSObject, ASWebAuthenticationPresentationContextProviding {
    private var listener: NWListener?
    private var authenticationSession: ASWebAuthenticationSession?
    private var deviceTask: Task<Void, Never>?
    private var completion: ((Result<AuthTokens, Error>) -> Void)?
    private var verifier = ""
    private var expectedState = ""
    private var expectedNonce = ""
    private var attemptID = UUID()
    private var redirectURI = ""
    private var portIndex = 0
    private let networkQueue = DispatchQueue(label: "codex-meter.oauth-callback")

    func start(using method: SignInMethod, completion: @escaping (Result<AuthTokens, Error>) -> Void) {
        cancel(notify: false)
        self.completion = completion
        verifier = Self.randomURLSafe(byteCount: 32)
        expectedState = Self.randomURLSafe(byteCount: 24)
        expectedNonce = Self.randomURLSafe(byteCount: 24)
        portIndex = 0
        switch method {
        case .browser:
            bindNextPort()
        case .deviceCode:
            deviceTask = Task { [weak self] in
                await self?.startDeviceCodeFlow()
            }
        }
    }

    func cancel(notify: Bool = true) {
        attemptID = UUID()
        let pendingCompletion = completion
        completion = nil
        deviceTask?.cancel()
        deviceTask = nil
        listener?.cancel()
        listener = nil
        authenticationSession?.cancel()
        authenticationSession = nil
        if notify, let pendingCompletion {
            pendingCompletion(.failure(MeterError.message("Sign-in cancelled.")))
        }
    }

    private func startDeviceCodeFlow() async {
        let attempt = attemptID
        do {
            let authorization = try await DeviceCodeAuth.requestAuthorization()
            try Task.checkCancellation()

            UIPasteboard.general.string = authorization.userCode
            let opened = await UIApplication.shared.open(authorization.verificationURL)
            guard opened else {
                throw MeterError.message("Could not open Safari for ChatGPT sign-in.")
            }

            let response = try await DeviceCodeAuth.pollForAuthorization(authorization)
            try Task.checkCancellation()
            let tokens = try await AuthAPI.shared.exchange(
                code: response.authorizationCode,
                redirectURI: "https://auth.openai.com/deviceauth/callback",
                verifier: response.codeVerifier
            )
            let matches = await AuthAPI.shared.matchingLegacyAccounts(for: tokens, existing: KeychainTokenStore.loadAll())
            try Task.checkCancellation()
            guard attempt == attemptID, completion != nil else { return }
            let connected = try KeychainTokenStore.repository.connect(tokens, matchingLegacy: matches)
            finish(.success(connected))
        } catch is CancellationError {
            return
        } catch {
            guard attempt == attemptID, completion != nil else { return }
            finish(.failure(error))
        }
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        return scenes.flatMap(\.windows).first(where: \.isKeyWindow) ?? ASPresentationAnchor()
    }

    private func bindNextPort() {
        guard portIndex < CodexConstants.callbackPorts.count else {
            finish(.failure(MeterError.message("Could not open the local OAuth callback port (1455 or 1457).")))
            return
        }
        let rawPort = CodexConstants.callbackPorts[portIndex]
        portIndex += 1
        guard let port = NWEndpoint.Port(rawValue: rawPort) else { return bindNextPort() }
        do {
            let candidate = try NWListener(using: .tcp, on: port)
            candidate.newConnectionHandler = { [weak self] connection in
                self?.accept(connection)
            }
            candidate.stateUpdateHandler = { [weak self, weak candidate] state in
                Task { @MainActor in
                    guard let self, self.listener === candidate else { return }
                    switch state {
                    case .ready:
                        self.openBrowser(port: rawPort)
                    case .failed:
                        candidate?.cancel()
                        self.listener = nil
                        self.bindNextPort()
                    default:
                        break
                    }
                }
            }
            listener = candidate
            candidate.start(queue: networkQueue)
        } catch {
            bindNextPort()
        }
    }

    private func openBrowser(port: UInt16) {
        redirectURI = "http://localhost:\(port)/auth/callback"
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncodedString()
        var components = URLComponents(url: CodexConstants.authorizeURL, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: CodexConstants.clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "scope", value: CodexConstants.scope),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "id_token_add_organizations", value: "true"),
            URLQueryItem(name: "codex_cli_simplified_flow", value: "true"),
            URLQueryItem(name: "state", value: expectedState),
            URLQueryItem(name: "nonce", value: expectedNonce),
            URLQueryItem(name: "originator", value: CodexConstants.originator)
        ]
        guard let url = components.url else {
            finish(.failure(MeterError.message("Could not create the ChatGPT sign-in URL.")))
            return
        }
        let session = ASWebAuthenticationSession(url: url, callbackURLScheme: nil) { [weak self] _, error in
            Task { @MainActor in
                guard let self, self.completion != nil, let error else { return }
                if (error as? ASWebAuthenticationSessionError)?.code == .canceledLogin {
                    self.finish(.failure(MeterError.message("Sign-in cancelled.")))
                }
            }
        }
        session.presentationContextProvider = self
        // When an account already exists, avoid silently reusing its browser session.
        session.prefersEphemeralWebBrowserSession = !KeychainTokenStore.loadAll().isEmpty
        authenticationSession = session
        guard session.start() else {
            finish(.failure(MeterError.message("Could not open ChatGPT sign-in.")))
            return
        }
    }

    nonisolated private func accept(_ connection: NWConnection) {
        connection.start(queue: networkQueue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, _, error in
            guard let self else { return }
            guard error == nil, let data, let request = String(data: data, encoding: .utf8) else {
                connection.cancel()
                return
            }
            let firstLine = request.components(separatedBy: "\r\n").first ?? ""
            let parts = firstLine.split(separator: " ")
            guard parts.count >= 2, parts[0] == "GET" else {
                Self.respond(connection, status: 405, message: "Unsupported callback request.", success: false)
                return
            }
            let target = String(parts[1])
            Task { @MainActor in self.handleCallback(target: target, connection: connection) }
        }
    }

    private func handleCallback(target: String, connection: NWConnection) {
        guard completion != nil else {
            Self.respond(connection, status: 400, message: "This sign-in is no longer active.", success: false)
            return
        }
        guard let components = URLComponents(string: "http://localhost\(target)"), components.path == "/auth/callback" else {
            Self.respond(connection, status: 404, message: "Not found.", success: false)
            return
        }
        let values = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        guard values["state"] == expectedState else {
            Self.respond(connection, status: 400, message: "The sign-in state did not match. Return to Codex Meter and try again.", success: false)
            return
        }
        if let error = values["error"], !error.isEmpty {
            let message = values["error_description"].flatMap { $0.isEmpty ? nil : $0 } ?? error
            Self.respond(connection, status: 400, message: message, success: false)
            finish(.failure(MeterError.message("Sign-in failed: \(message)")))
            return
        }
        guard let code = values["code"], !code.isEmpty else {
            Self.respond(connection, status: 400, message: "The authorization response did not include a code.", success: false)
            finish(.failure(MeterError.message("Sign-in failed because no authorization code was returned.")))
            return
        }
        let redirect = redirectURI
        let verifier = verifier
        let nonce = expectedNonce
        let attempt = attemptID
        Task {
            do {
                let tokens = try await AuthAPI.shared.exchange(code: code, redirectURI: redirect, verifier: verifier, nonce: nonce)
                let matches = await AuthAPI.shared.matchingLegacyAccounts(for: tokens, existing: KeychainTokenStore.loadAll())
                guard attempt == attemptID, completion != nil else {
                    Self.respond(connection, status: 400, message: "This sign-in is no longer active.", success: false)
                    return
                }
                let connected = try KeychainTokenStore.repository.connect(tokens, matchingLegacy: matches)
                Self.respond(connection, status: 200, message: "Your ChatGPT account is connected. You can close this page and return to Codex Meter.", success: true)
                self.finish(.success(connected))
            } catch {
                Self.respond(connection, status: 500, message: error.localizedDescription, success: false)
                guard attempt == attemptID, completion != nil else { return }
                self.finish(.failure(error))
            }
        }
    }

    private func finish(_ result: Result<AuthTokens, Error>) {
        attemptID = UUID()
        let pendingCompletion = completion
        completion = nil
        deviceTask?.cancel()
        deviceTask = nil
        listener?.cancel()
        listener = nil
        authenticationSession?.cancel()
        authenticationSession = nil
        pendingCompletion?(result)
    }

    nonisolated private static func respond(_ connection: NWConnection, status: Int, message: String, success: Bool) {
        let escaped = message
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
        let title = success ? "You’re connected" : "Let’s try that again"
        let color = success ? "#10a37f" : "#ff6b7a"
        let html = """
        <!doctype html><html><head><meta name="viewport" content="width=device-width,initial-scale=1">
        <style>body{margin:0;background:#090a11;color:#f7f7fc;font-family:-apple-system;display:grid;place-items:center;min-height:100vh;padding:24px;box-sizing:border-box}.card{background:#171927;border:1px solid #303342;border-radius:28px;padding:30px;max-width:420px}b{color:\(color);font-size:13px}h1{font-size:30px;margin:12px 0}p{color:#a6a8b5;line-height:1.5}</style></head>
        <body><main class="card"><b>CODEX METER</b><h1>\(title)</h1><p>\(escaped)</p></main></body></html>
        """
        let body = Data(html.utf8)
        let reason = (200..<300).contains(status) ? "OK" : "Error"
        let header = "HTTP/1.1 \(status) \(reason)\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.count)\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(header.utf8) + body, completion: .contentProcessed { _ in connection.cancel() })
    }

    private static func randomURLSafe(byteCount: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        guard SecRandomCopyBytes(kSecRandomDefault, byteCount, &bytes) == errSecSuccess else {
            return UUID().uuidString.replacingOccurrences(of: "-", with: "")
        }
        return Data(bytes).base64URLEncodedString()
    }
}

private enum DeviceCodeAuth {
    enum Error: LocalizedError {
        case unavailable
        case requestFailed(Int)
        case authorizationFailed(Int)
        case timedOut

        var errorDescription: String? {
            switch self {
            case .unavailable:
                "Device-code sign-in is unavailable."
            case let .requestFailed(status):
                "Could not start ChatGPT device sign-in (HTTP \(status))."
            case let .authorizationFailed(status):
                "ChatGPT device sign-in failed (HTTP \(status))."
            case .timedOut:
                "ChatGPT sign-in timed out. Try again."
            }
        }
    }

    struct Authorization: Sendable {
        let verificationURL: URL
        let userCode: String
        let deviceAuthID: String
        let interval: TimeInterval
    }

    struct AuthorizationResponse: Sendable {
        let authorizationCode: String
        let codeVerifier: String
    }

    private struct UserCodeResponse: Decodable {
        let deviceAuthID: String
        let userCode: String
        let interval: TimeInterval

        enum CodingKeys: String, CodingKey {
            case deviceAuthID = "device_auth_id"
            case userCode = "user_code"
            case usercode
            case interval
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            deviceAuthID = try container.decode(String.self, forKey: .deviceAuthID)
            userCode = try container.decodeIfPresent(String.self, forKey: .userCode)
                ?? container.decode(String.self, forKey: .usercode)
            if let value = try? container.decode(Int.self, forKey: .interval) {
                interval = TimeInterval(value)
            } else {
                interval = TimeInterval(try container.decode(String.self, forKey: .interval)) ?? 5
            }
        }
    }

    private struct PollResponse: Decodable {
        let authorizationCode: String
        let codeVerifier: String

        enum CodingKeys: String, CodingKey {
            case authorizationCode = "authorization_code"
            case codeVerifier = "code_verifier"
        }
    }

    static func requestAuthorization() async throws -> Authorization {
        let url = URL(string: "https://auth.openai.com/api/accounts/deviceauth/usercode")!
        let body = try JSONSerialization.data(withJSONObject: ["client_id": CodexConstants.clientID])
        let (data, status) = try await post(url: url, body: body)
        if status == 404 { throw Error.unavailable }
        guard (200..<300).contains(status) else { throw Error.requestFailed(status) }
        let decoded = try JSONDecoder().decode(UserCodeResponse.self, from: data)
        return Authorization(
            verificationURL: URL(string: "https://auth.openai.com/codex/device")!,
            userCode: decoded.userCode,
            deviceAuthID: decoded.deviceAuthID,
            interval: max(1, decoded.interval)
        )
    }

    static func pollForAuthorization(_ authorization: Authorization) async throws -> AuthorizationResponse {
        let url = URL(string: "https://auth.openai.com/api/accounts/deviceauth/token")!
        let deadline = Date().addingTimeInterval(15 * 60)
        while Date() < deadline {
            try Task.checkCancellation()
            let body = try JSONSerialization.data(withJSONObject: [
                "device_auth_id": authorization.deviceAuthID,
                "user_code": authorization.userCode
            ])
            let (data, status) = try await post(url: url, body: body)
            if (200..<300).contains(status) {
                let decoded = try JSONDecoder().decode(PollResponse.self, from: data)
                return AuthorizationResponse(
                    authorizationCode: decoded.authorizationCode,
                    codeVerifier: decoded.codeVerifier
                )
            }
            guard status == 403 || status == 404 else { throw Error.authorizationFailed(status) }
            try await Task.sleep(for: .seconds(authorization.interval))
        }
        throw Error.timedOut
    }

    private static func post(url: URL, body: Data) async throws -> (Data, Int) {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = body
        request.timeoutInterval = 25
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("codex-meter-ios/0.1", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw MeterError.message("ChatGPT device sign-in returned an invalid response.")
        }
        return (data, http.statusCode)
    }
}

private extension Data {
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
