import Foundation

// UserDefaults is thread-safe; mutations used by the app are serialized by CodexAPI.
public struct AccountCacheStore: @unchecked Sendable {
    public let defaults: UserDefaults
    public let sharedDefaults: UserDefaults?

    public init(defaults: UserDefaults = .standard, sharedDefaults: UserDefaults? = UserDefaults(suiteName: SharedStore.suiteName)) {
        self.defaults = defaults
        self.sharedDefaults = sharedDefaults
    }

    public func usage(localAccountId: String) -> UsageSnapshot? { read(UsageSnapshot.self, key: usageKey(localAccountId)) }
    public func credits(localAccountId: String) -> ResetCreditsSnapshot? { read(ResetCreditsSnapshot.self, key: creditsKey(localAccountId)) }

    public func save(usage: UsageSnapshot, credits: ResetCreditsSnapshot?, localAccountId: String) {
        write(usage, key: usageKey(localAccountId))
        if let credits { write(credits, key: creditsKey(localAccountId)) }
    }

    public func remove(localAccountId: String) {
        for key in [usageKey(localAccountId), creditsKey(localAccountId)] {
            defaults.removeObject(forKey: key)
            sharedDefaults?.removeObject(forKey: key)
        }
    }

    public func migrateLegacyGlobalCache(accounts: [AuthTokens]) {
        // Global v1 snapshots have no owner field. Claim them only when the v1
        // credential is the sole remaining account, never for a newly added member.
        guard accounts.count == 1, let owner = accounts.first, owner.ownsLegacyGlobalCache else { return }
        for (old, destination) in [(SharedStore.usageKey, usageKey(owner.localAccountId)),
                                    (SharedStore.creditsKey, creditsKey(owner.localAccountId))] {
            guard let data = sharedDefaults?.data(forKey: old) ?? defaults.data(forKey: old) else { continue }
            if defaults.data(forKey: destination) == nil && sharedDefaults?.data(forKey: destination) == nil {
                defaults.set(data, forKey: destination)
            }
            guard defaults.data(forKey: destination) != nil || sharedDefaults?.data(forKey: destination) != nil else { continue }
            defaults.removeObject(forKey: old)
            sharedDefaults?.removeObject(forKey: old)
        }
    }

    private func usageKey(_ id: String) -> String { "usage-snapshot-v2.\(id)" }
    private func creditsKey(_ id: String) -> String { "reset-credits-v2.\(id)" }

    private func write<T: Encodable>(_ value: T, key: String) {
        if let data = try? JSONEncoder().encode(value) { defaults.set(data, forKey: key) }
    }

    private func read<T: Decodable>(_ type: T.Type, key: String) -> T? {
        guard let data = sharedDefaults?.data(forKey: key) ?? defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
}
