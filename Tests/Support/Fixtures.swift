import CodexMeterCore
import Foundation
import Security

public final class TestSigner: @unchecked Sendable {
    private let key: SecKey
    public let jwks: Data
    public let kid = "synthetic-test-key"

    public init() throws {
        let signingKey = SecKeyCreateRandomKey([
            kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeySizeInBits: 2048,
            kSecAttrIsPermanent: false
        ] as CFDictionary, nil)!
        key = signingKey
        let publicKey = SecKeyCopyPublicKey(signingKey)!
        let representation = SecKeyCopyExternalRepresentation(publicKey, nil)! as Data
        let bytes = Array(representation)
        var offset = 0
        func element(_ expected: UInt8) -> Data {
            precondition(bytes[offset] == expected)
            offset += 1
            var length = Int(bytes[offset]); offset += 1
            if length & 0x80 != 0 {
                let count = length & 0x7f
                length = 0
                for _ in 0..<count { length = (length << 8) | Int(bytes[offset]); offset += 1 }
            }
            let start = offset
            if expected != 0x30 { offset += length }
            return Data(bytes[start..<start + length])
        }
        _ = element(0x30)
        let modulus = element(0x02).drop(while: { $0 == 0 })
        let exponent = element(0x02)
        jwks = try JSONSerialization.data(withJSONObject: ["keys": [[
            "kid": "synthetic-test-key", "kty": "RSA", "alg": "RS256", "use": "sig",
            "n": Self.base64(Data(modulus)), "e": Self.base64(exponent)
        ]]])
    }

    public func token(subject: String = "user-a", workspace: String = "business-workspace",
                      email: String = "same@example.invalid", now: Date = .now,
                      overrides: [String: Any] = [:], headerOverrides: [String: Any] = [:]) throws -> String {
        var claims: [String: Any] = [
            "iss": IDTokenValidator.issuer, "sub": subject, "aud": IDTokenValidator.clientID,
            "iat": now.timeIntervalSince1970 - 30, "exp": now.timeIntervalSince1970 + 3_600,
            "email": email, "https://api.openai.com/auth": ["chatgpt_account_id": workspace]
        ]
        claims.merge(overrides) { _, value in value }
        var header: [String: Any] = ["alg": "RS256", "kid": kid]
        header.merge(headerOverrides) { _, value in value }
        let message = Self.base64(try JSONSerialization.data(withJSONObject: header)) + "."
            + Self.base64(try JSONSerialization.data(withJSONObject: claims))
        let signature = SecKeyCreateSignature(key, .rsaSignatureMessagePKCS1v15SHA256, Data(message.utf8) as CFData, nil)! as Data
        return message + "." + Self.base64(signature)
    }

    public static func base64(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}

public func tokens(_ subject: String = "user-a", workspace: String = "business-workspace",
                   suffix: String = "", expiresAt: Date = .distantFuture, localID: String? = nil) -> AuthTokens {
    let identity = AccountIdentity(issuer: IDTokenValidator.issuer, subject: subject, workspaceId: workspace)
    return AuthTokens(accessToken: "synthetic-access-\(subject)\(suffix)", refreshToken: "synthetic-refresh-\(subject)\(suffix)",
                      idToken: "synthetic-id-token", expiresAt: expiresAt, accountId: workspace,
                      email: "same@example.invalid", localAccountId: localID ?? identity.localAccountId, identity: identity)
}

public func legacyData(_ token: AuthTokens, idToken: String? = nil) throws -> Data {
    var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(token)) as! [String: Any]
    for key in ["identity", "localAccountId", "ownsLegacyGlobalCache"] { object.removeValue(forKey: key) }
    if let idToken { object["idToken"] = idToken }
    return try JSONSerialization.data(withJSONObject: object)
}

public final class MemoryCredentials: CredentialStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]
    public var failWrites = false
    public var failDeletes = false
    public var corruptWrites = false
    public init() {}
    public func items() throws -> [String: Data] { lock.lock(); defer { lock.unlock() }; return values }
    public func write(_ data: Data, for key: String) throws {
        lock.lock(); defer { lock.unlock() }
        if failWrites { throw MeterError.message("synthetic write failure") }
        values[key] = corruptWrites ? Data("invalid".utf8) : data
    }
    public func remove(_ key: String) throws {
        lock.lock(); defer { lock.unlock() }
        if failDeletes { throw MeterError.message("synthetic delete failure") }
        values.removeValue(forKey: key)
    }
    public func removeAll() throws { lock.lock(); defer { lock.unlock() }; values = [:] }
}

public final class MockHTTP: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var handler: (@Sendable (URLRequest) throws -> (Int, Data))?
    public static func session(_ handler: @escaping @Sendable (URLRequest) throws -> (Int, Data)) -> URLSession {
        lock.lock(); self.handler = handler; lock.unlock()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockHTTP.self]
        return URLSession(configuration: config)
    }
    public override class func canInit(with request: URLRequest) -> Bool { true }
    public override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    public override func startLoading() {
        do {
            Self.lock.lock(); let handler = Self.handler; Self.lock.unlock()
            guard let handler else { throw MeterError.message("No synthetic HTTP handler") }
            let (status, data) = try handler(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    public override func stopLoading() {}
}

public func requestBody(_ request: URLRequest) -> Data {
    if let body = request.httpBody { return body }
    guard let stream = request.httpBodyStream else { return Data() }
    stream.open(); defer { stream.close() }
    var result = Data()
    var buffer = [UInt8](repeating: 0, count: 4_096)
    while stream.hasBytesAvailable {
        let count = stream.read(&buffer, maxLength: buffer.count)
        if count <= 0 { break }
        result.append(contentsOf: buffer.prefix(count))
    }
    return result
}
