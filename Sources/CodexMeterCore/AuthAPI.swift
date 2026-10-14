import Foundation

public enum CodexConstants {
    public static let authorizeURL = URL(string: "https://auth.openai.com/oauth/authorize")!
    public static let tokenURL = URL(string: "https://auth.openai.com/oauth/token")!
    public static let revokeURL = URL(string: "https://auth.openai.com/oauth/revoke")!
    public static let usageURL = URL(string: "https://chatgpt.com/backend-api/wham/usage")!
    public static let resetCreditsURL = URL(string: "https://chatgpt.com/backend-api/wham/rate-limit-reset-credits")!
    public static let consumeResetURL = URL(string: "https://chatgpt.com/backend-api/wham/rate-limit-reset-credits/consume")!
    public static let clientID = IDTokenValidator.clientID
    public static let scope = "openid profile email offline_access"
    public static let originator = "codex-meter-ios"
    public static let callbackPorts: [UInt16] = [1455, 1457]
}

public actor AuthAPI {
    public static let shared = AuthAPI()
    private let session: URLSession
    private var signingKeys: Data?
    private var keysFetchedAt = Date.distantPast

    public init(session: URLSession = .shared) { self.session = session }

    public func exchange(code: String, redirectURI: String, verifier: String, nonce: String? = nil) async throws -> AuthTokens {
        let body = formEncoded([
            "grant_type": "authorization_code", "code": code, "redirect_uri": redirectURI,
            "client_id": CodexConstants.clientID, "code_verifier": verifier
        ])
        return try await tokenRequest(body: body, contentType: "application/x-www-form-urlencoded", previous: nil, nonce: nonce)
    }

    public func refresh(_ previous: AuthTokens) async throws -> AuthTokens {
        let body = try JSONSerialization.data(withJSONObject: [
            "grant_type": "refresh_token", "refresh_token": previous.refreshToken, "client_id": CodexConstants.clientID
        ])
        return try await tokenRequest(body: body, contentType: "application/json", previous: previous, nonce: nil)
    }

    public func revoke(_ tokens: AuthTokens) async {
        guard let body = try? JSONSerialization.data(withJSONObject: [
            "token": tokens.refreshToken, "token_type_hint": "refresh_token", "client_id": CodexConstants.clientID
        ]) else { return }
        var request = URLRequest(url: CodexConstants.revokeURL)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        _ = try? await session.data(for: request)
    }

    public func matchingLegacyAccounts(for tokens: AuthTokens, existing: [AuthTokens]) async -> [AuthTokens] {
        guard let identity = tokens.identity else { return [] }
        var matches: [AuthTokens] = []
        for old in existing where old.identity == nil && old.accountId == tokens.accountId {
            // A historical signature is only a migration binding. The NEW login above
            // must already have passed full validation, including expiration and nonce.
            if let keys = try? await jwks(),
               let binding = try? IDTokenValidator.legacyBinding(old.idToken, jwks: keys), binding == identity {
                matches.append(old)
            }
        }
        return matches
    }

    private func tokenRequest(body: Data, contentType: String, previous: AuthTokens?, nonce: String?) async throws -> AuthTokens {
        var request = URLRequest(url: CodexConstants.tokenURL)
        request.httpMethod = "POST"
        request.httpBody = body
        request.timeoutInterval = 25
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("codex-meter-ios/0.1", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              http.url == CodexConstants.tokenURL else {
            throw MeterError.message("ChatGPT authentication failed. Please sign in again.")
        }
        let decoded = try JSONDecoder().decode(TokenResponse.self, from: data)
        let identity: AccountIdentity
        let email: String
        if let token = decoded.idToken, !token.isEmpty {
            let claims = try await validateIdentity(token, nonce: nonce)
            identity = claims.identity
            email = claims.email.isEmpty ? previous?.email ?? "" : claims.email
        } else if let previous, let knownIdentity = previous.identity {
            // OIDC refresh responses may omit id_token. Retain the already validated
            // identity and workspace; never derive a new identity from the access token.
            identity = knownIdentity
            email = previous.email
        } else if let previous {
            // A successful refresh authenticates the existing credential. Validate its
            // historical ID token before binding a legacy local ID to a member.
            identity = try IDTokenValidator.legacyBinding(previous.idToken, jwks: await jwks())
            email = previous.email
        } else {
            throw MeterError.message("ChatGPT did not return a verifiable account identity.")
        }
        if let previous {
            guard previous.accountId == identity.workspaceId,
                  previous.identity == nil || previous.identity == identity else {
                throw MeterError.message("The refreshed ChatGPT identity changed. Please reconnect this account.")
            }
        }
        let tokens = AuthTokens(
            accessToken: decoded.accessToken,
            refreshToken: decoded.refreshToken.flatMap { $0.isEmpty ? nil : $0 } ?? previous?.refreshToken ?? "",
            idToken: decoded.idToken.flatMap { $0.isEmpty ? nil : $0 } ?? previous?.idToken ?? "",
            expiresAt: Date().addingTimeInterval(TimeInterval(max(60, decoded.expiresIn ?? 3_600))),
            accountId: identity.workspaceId, email: email,
            localAccountId: previous?.localAccountId ?? identity.localAccountId, identity: identity,
            ownsLegacyGlobalCache: previous?.ownsLegacyGlobalCache ?? false
        )
        guard tokens.isUsable else { throw MeterError.message("The authorization server returned incomplete credentials.") }
        return tokens
    }

    private func validateIdentity(_ token: String, nonce: String?) async throws -> ValidatedIDToken {
        let keys = try await jwks()
        do { return try IDTokenValidator.validate(token, jwks: keys, nonce: nonce) }
        catch {
            // Retry once with fresh public keys to handle signing-key rotation.
            return try IDTokenValidator.validate(token, jwks: await jwks(force: true), nonce: nonce)
        }
    }

    private func jwks(force: Bool = false) async throws -> Data {
        if !force, let signingKeys, keysFetchedAt.timeIntervalSinceNow > -3_600 { return signingKeys }
        var request = URLRequest(url: IDTokenValidator.jwksURL)
        request.timeoutInterval = 25
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200, http.url == IDTokenValidator.jwksURL else {
            throw MeterError.message("Could not load ChatGPT identity verification keys. Please try again.")
        }
        signingKeys = data
        keysFetchedAt = .now
        return data
    }

    private func formEncoded(_ values: [String: String]) -> Data {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        return Data(values.map { key, value in
            "\(key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key)=\(value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value)"
        }.joined(separator: "&").utf8)
    }
}

private struct TokenResponse: Decodable {
    let accessToken: String
    let refreshToken: String?
    let idToken: String?
    let expiresIn: Int?
    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token", refreshToken = "refresh_token", idToken = "id_token", expiresIn = "expires_in"
    }
}
