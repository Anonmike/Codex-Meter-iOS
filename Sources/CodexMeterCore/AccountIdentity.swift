import CryptoKit
import Foundation

/// The issuer's user subject and the selected ChatGPT workspace are separate IDs.
/// Only construct this from a validated ID token in the authentication flow.
public struct AccountIdentity: Codable, Equatable, Sendable {
    public let issuer: String
    public let subject: String
    public let workspaceId: String

    public init(issuer: String, subject: String, workspaceId: String) {
        self.issuer = issuer
        self.subject = subject
        self.workspaceId = workspaceId
    }

    public var localAccountId: String {
        // Length framing avoids delimiter collisions. No subject is exposed to widgets.
        let parts = [issuer, subject, workspaceId].map { "\($0.utf8.count):\($0)" }.joined()
        return "member-v3:" + SHA256.hash(data: Data(parts.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

public struct AuthTokens: Codable, Equatable, Sendable {
    public let accessToken: String
    public let refreshToken: String
    public let idToken: String
    public let expiresAt: Date
    /// Workspace ID used exclusively for ChatGPT request routing; keep the v1/v2 coding key.
    public let accountId: String
    public let email: String
    public let localAccountId: String
    public let identity: AccountIdentity?
    public let ownsLegacyGlobalCache: Bool

    public init(accessToken: String, refreshToken: String, idToken: String, expiresAt: Date,
                accountId: String, email: String, localAccountId: String,
                identity: AccountIdentity?, ownsLegacyGlobalCache: Bool = false) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.idToken = idToken
        self.expiresAt = expiresAt
        self.accountId = accountId
        self.email = email
        self.localAccountId = localAccountId
        self.identity = identity
        self.ownsLegacyGlobalCache = ownsLegacyGlobalCache
    }

    private enum CodingKeys: String, CodingKey {
        case accessToken, refreshToken, idToken, expiresAt, accountId, email
        case localAccountId, identity, ownsLegacyGlobalCache
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        accessToken = try values.decode(String.self, forKey: .accessToken)
        refreshToken = try values.decode(String.self, forKey: .refreshToken)
        idToken = try values.decode(String.self, forKey: .idToken)
        expiresAt = try values.decode(Date.self, forKey: .expiresAt)
        accountId = try values.decode(String.self, forKey: .accountId)
        email = try values.decode(String.self, forKey: .email)
        // Preserve legacy IDs and all the local metadata that already refers to them.
        localAccountId = try values.decodeIfPresent(String.self, forKey: .localAccountId) ?? accountId
        identity = try values.decodeIfPresent(AccountIdentity.self, forKey: .identity)
        ownsLegacyGlobalCache = try values.decodeIfPresent(Bool.self, forKey: .ownsLegacyGlobalCache) ?? false
    }

    public var isUsable: Bool { !accessToken.isEmpty && !refreshToken.isEmpty && !accountId.isEmpty && !localAccountId.isEmpty }
    public var shouldRefresh: Bool { expiresAt.timeIntervalSinceNow < 300 }

    public func keepingLocalIdentity(of previous: AuthTokens) -> AuthTokens {
        AuthTokens(accessToken: accessToken, refreshToken: refreshToken, idToken: idToken,
                   expiresAt: expiresAt, accountId: accountId, email: email,
                   localAccountId: previous.localAccountId, identity: identity,
                   ownsLegacyGlobalCache: previous.ownsLegacyGlobalCache)
    }

    public func owningLegacyGlobalCache() -> AuthTokens {
        AuthTokens(accessToken: accessToken, refreshToken: refreshToken, idToken: idToken,
                   expiresAt: expiresAt, accountId: accountId, email: email,
                   localAccountId: localAccountId, identity: identity, ownsLegacyGlobalCache: true)
    }
}
