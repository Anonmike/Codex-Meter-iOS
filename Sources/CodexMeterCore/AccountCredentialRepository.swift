import Foundation

public protocol CredentialStorage: Sendable {
    func items() throws -> [String: Data]
    func write(_ data: Data, for key: String) throws
    func remove(_ key: String) throws
    func removeAll() throws
}

/// Serializes Keychain migration, reconnect, refresh commits and logout. A network
/// response may replace only the exact credential that initiated its request.
public final class AccountCredentialRepository: @unchecked Sendable {
    public static let prefix = "chatgpt-oauth-v3:"
    public static let legacyPrefix = "chatgpt-oauth-v2:"
    public static let legacyAccount = "chatgpt-oauth-v1"
    private let storage: any CredentialStorage
    private let lock = NSRecursiveLock()

    public init(storage: any CredentialStorage) { self.storage = storage }

    public func loadAll() -> [AuthTokens] {
        lock.lock()
        defer { lock.unlock() }
        guard var items = try? storage.items() else { return [] }
        for (key, data) in items where key == Self.legacyAccount || key.hasPrefix(Self.legacyPrefix) {
            guard var tokens = try? JSONDecoder().decode(AuthTokens.self, from: data), tokens.isUsable else { continue }
            if key == Self.legacyAccount { tokens = tokens.owningLegacyGlobalCache() }
            let destination = Self.prefix + tokens.localAccountId
            do {
                // Never overwrite a destination that may contain a newer credential.
                if let saved = items[destination] {
                    guard try JSONDecoder().decode(AuthTokens.self, from: saved) == tokens else { continue }
                } else {
                    try storage.write(JSONEncoder().encode(tokens), for: destination)
                    guard let saved = try storage.items()[destination],
                          try JSONDecoder().decode(AuthTokens.self, from: saved) == tokens else { continue }
                    items[destination] = saved
                }
                try storage.remove(key)
                items.removeValue(forKey: key)
            } catch {
                // Keep the source on write, read-back or deletion failure; retry later.
            }
        }
        var result: [String: AuthTokens] = [:]
        for (key, data) in items.sorted(by: { $0.key < $1.key }) {
            guard key.hasPrefix(Self.prefix) || key.hasPrefix(Self.legacyPrefix) || key == Self.legacyAccount,
                  var tokens = try? JSONDecoder().decode(AuthTokens.self, from: data), tokens.isUsable else { continue }
            if key == Self.legacyAccount { tokens = tokens.owningLegacyGlobalCache() }
            if result[tokens.localAccountId] == nil || key.hasPrefix(Self.prefix) { result[tokens.localAccountId] = tokens }
        }
        return result.values.sorted {
            let left = $0.email.isEmpty ? $0.localAccountId : $0.email
            let right = $1.email.isEmpty ? $1.localAccountId : $1.email
            return left.localizedCaseInsensitiveCompare(right) == .orderedAscending
        }
    }

    public func load(localAccountId: String) -> AuthTokens? {
        loadAll().first { $0.localAccountId == localAccountId }
    }

    @discardableResult
    public func connect(_ tokens: AuthTokens, matchingLegacy: [AuthTokens] = []) throws -> AuthTokens {
        lock.lock()
        defer { lock.unlock() }
        guard let identity = tokens.identity, identity.workspaceId == tokens.accountId, tokens.isUsable else {
            throw MeterError.message("ChatGPT did not return a verified account identity.")
        }
        let existing = loadAll()
        let match = existing.first { $0.identity == identity }
            ?? existing.first { $0.identity == nil && matchingLegacy.contains($0) }
        let connected = match.map { tokens.keepingLocalIdentity(of: $0) } ?? tokens
        if let occupied = existing.first(where: { $0.localAccountId == connected.localAccountId }), occupied != match {
            throw MeterError.message("This local credential belongs to a different account.")
        }
        try storage.write(JSONEncoder().encode(connected), for: Self.prefix + connected.localAccountId)
        return connected
    }

    public func replace(_ tokens: AuthTokens, ifCurrent previous: AuthTokens) throws {
        lock.lock()
        defer { lock.unlock() }
        guard load(localAccountId: previous.localAccountId) == previous,
              tokens.localAccountId == previous.localAccountId, tokens.accountId == previous.accountId,
              previous.identity == nil || previous.identity == tokens.identity else {
            throw MeterError.message("This ChatGPT session changed while refreshing. Please try again.")
        }
        try storage.write(JSONEncoder().encode(tokens), for: Self.prefix + tokens.localAccountId)
    }

    public func remove(localAccountId: String) throws {
        lock.lock()
        defer { lock.unlock() }
        // Also remove a retained migration source, so it cannot resurrect on launch.
        for (key, data) in try storage.items() {
            guard key.hasPrefix(Self.prefix) || key.hasPrefix(Self.legacyPrefix) || key == Self.legacyAccount,
                  let token = try? JSONDecoder().decode(AuthTokens.self, from: data), token.localAccountId == localAccountId else { continue }
            try storage.remove(key)
        }
    }

    public func clearAll() throws {
        lock.lock()
        defer { lock.unlock() }
        try storage.removeAll()
    }
}
