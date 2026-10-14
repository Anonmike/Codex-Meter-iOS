import Foundation
import Security

public struct ValidatedIDToken: Equatable, Sendable {
    public let identity: AccountIdentity
    public let email: String
}

public enum IDTokenValidator {
    public static let issuer = "https://auth.openai.com"
    public static let clientID = "app_EMoamEEZ73f0CkXaXp7hrann"
    public static let jwksURL = URL(string: "https://auth.openai.com/.well-known/jwks.json")!

    public static func validate(_ token: String, jwks: Data, nonce: String? = nil,
                                now: Date = .now) throws -> ValidatedIDToken {
        try validatedClaims(token, jwks: jwks, nonce: nonce, now: now, historical: false)
    }

    /// Historical tokens establish only ownership of a legacy record. This must never
    /// be used to accept a login or authorize a request; those require fresh credentials.
    public static func legacyBinding(_ token: String, jwks: Data, now: Date = .now) throws -> AccountIdentity {
        try validatedClaims(token, jwks: jwks, nonce: nil, now: now, historical: true).identity
    }

    private static func validatedClaims(_ token: String, jwks: Data, nonce: String?,
                                        now: Date, historical: Bool) throws -> ValidatedIDToken {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3,
              let headerData = decode(String(parts[0])), let payload = decode(String(parts[1])),
              let signature = decode(String(parts[2])),
              let header = try JSONSerialization.jsonObject(with: headerData) as? [String: Any],
              header["alg"] as? String == "RS256", header["crit"] == nil,
              let kid = header["kid"] as? String, !kid.isEmpty,
              let keys = try JSONSerialization.jsonObject(with: jwks) as? [String: Any],
              let candidates = keys["keys"] as? [[String: Any]]
        else { throw invalidIdentity() }
        let matching = candidates.filter { $0["kid"] as? String == kid }
        guard matching.count == 1, let key = matching.first,
              key["kty"] as? String == "RSA",
              key["use"] == nil || key["use"] as? String == "sig",
              key["alg"] == nil || key["alg"] as? String == "RS256",
              key["key_ops"] == nil || (key["key_ops"] as? [String])?.contains("verify") == true,
              let n = key["n"] as? String, let modulus = decode(n), modulus.count >= 256,
              let e = key["e"] as? String, let exponent = decode(e), !exponent.isEmpty
        else { throw invalidIdentity() }
        let der = sequence(integer(modulus) + integer(exponent))
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass as String: kSecAttrKeyClassPublic
        ]
        guard let publicKey = SecKeyCreateWithData(der as CFData, attributes as CFDictionary, nil),
              SecKeyVerifySignature(publicKey, .rsaSignatureMessagePKCS1v15SHA256,
                                    Data("\(parts[0]).\(parts[1])".utf8) as CFData, signature as CFData, nil),
              let claims = try JSONSerialization.jsonObject(with: payload) as? [String: Any],
              claims["iss"] as? String == issuer,
              let subject = claims["sub"] as? String, !subject.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { throw invalidIdentity() }
        let audiences = (claims["aud"] as? [String]) ?? (claims["aud"] as? String).map { [$0] } ?? []
        guard audiences.contains(clientID),
              (audiences.count <= 1 || claims["azp"] as? String == clientID),
              (claims["azp"] == nil || claims["azp"] as? String == clientID),
              let expires = timestamp(claims["exp"]), let issued = timestamp(claims["iat"]),
              issued <= now.timeIntervalSince1970 + 60, expires > issued,
              historical || expires > now.timeIntervalSince1970,
              claims["nbf"] == nil || (timestamp(claims["nbf"]) ?? .infinity) <= now.timeIntervalSince1970 + 60,
              nonce == nil || claims["nonce"] as? String == nonce
        else { throw invalidIdentity() }
        let auth = claims["https://api.openai.com/auth"] as? [String: Any]
        let topWorkspace = claims["chatgpt_account_id"] as? String
        let authWorkspace = auth?["chatgpt_account_id"] as? String
        guard topWorkspace == nil || authWorkspace == nil || topWorkspace == authWorkspace,
              let workspace = authWorkspace ?? topWorkspace,
              !workspace.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { throw invalidIdentity() }
        // An arbitrary first organization is not necessarily the selected workspace.
        return ValidatedIDToken(identity: AccountIdentity(issuer: issuer, subject: subject, workspaceId: workspace),
                                email: claims["email"] as? String
                                    ?? (claims["https://api.openai.com/profile"] as? [String: Any])?["email"] as? String ?? "")
    }

    private static func timestamp(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let result = number.doubleValue
        return result.isFinite ? result : nil
    }

    private static func decode(_ value: String) -> Data? {
        guard !value.isEmpty, value.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }) else { return nil }
        let padded = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
            + String(repeating: "=", count: (4 - value.count % 4) % 4)
        return Data(base64Encoded: padded)
    }

    private static func integer(_ data: Data) -> Data {
        var bytes = Data(data.drop(while: { $0 == 0 }))
        if bytes.isEmpty { bytes = Data([0]) }
        if bytes[bytes.startIndex] & 0x80 != 0 { bytes.insert(0, at: bytes.startIndex) }
        return Data([0x02]) + length(bytes.count) + bytes
    }

    private static func sequence(_ data: Data) -> Data { Data([0x30]) + length(data.count) + data }

    private static func length(_ count: Int) -> Data {
        if count < 128 { return Data([UInt8(count)]) }
        var value = count
        var bytes: [UInt8] = []
        while value > 0 { bytes.insert(UInt8(value & 0xff), at: 0); value >>= 8 }
        return Data([0x80 | UInt8(bytes.count)]) + Data(bytes)
    }

    private static func invalidIdentity() -> MeterError {
        .message("Could not verify the ChatGPT account identity. Please sign in again.")
    }
}
