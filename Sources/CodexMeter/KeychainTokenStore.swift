import Foundation
import Security
import CodexMeterCore

enum KeychainTokenStore {
    static let repository = AccountCredentialRepository(storage: KeychainCredentialStorage(service: "com.picklemike.codexmeter.auth"))

    static func load(accountId: String) -> AuthTokens? { repository.load(localAccountId: accountId) }
    static func loadAll() -> [AuthTokens] { repository.loadAll() }
    static func remove(accountId: String) throws { try repository.remove(localAccountId: accountId) }
    static func clearAll() throws { try repository.clearAll() }
}

/// Tests inject a unique service. Production retains the existing service and
/// accessibility, with a separate v3 account for each local identity.
struct KeychainCredentialStorage: CredentialStorage {
    let service: String

    func items() throws -> [String: Data] {
        var query = baseQuery
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitAll
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return [:] }
        try check(status, operation: "read")
        var items: [String: Data] = [:]
        for item in result as? [[String: Any]] ?? [] {
            guard let key = item[kSecAttrAccount as String] as? String else { continue }
            // macOS does not permit returning every password's data in one query.
            // Enumerate attributes, then read only the specific credential item.
            var dataQuery = baseQuery
            dataQuery[kSecAttrAccount as String] = key
            dataQuery[kSecReturnData as String] = true
            dataQuery[kSecMatchLimit as String] = kSecMatchLimitOne
            var value: CFTypeRef?
            let dataStatus = SecItemCopyMatching(dataQuery as CFDictionary, &value)
            if dataStatus == errSecItemNotFound { continue }
            try check(dataStatus, operation: "read")
            if let data = value as? Data { items[key] = data }
        }
        return items
    }

    func write(_ data: Data, for key: String) throws {
        var query = baseQuery
        query[kSecAttrAccount as String] = key
        var attributes: [String: Any] = [kSecValueData as String: data]
        #if os(iOS)
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        #endif
        // The host tests use the macOS file Keychain, which has no iOS
        // accessibility classes. iOS retains its existing device-only protection.
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            try check(SecItemAdd(query.merging(attributes) { _, new in new } as CFDictionary, nil), operation: "add")
        } else { try check(status, operation: "update") }
    }

    func remove(_ key: String) throws {
        var query = baseQuery
        query[kSecAttrAccount as String] = key
        let status = SecItemDelete(query as CFDictionary)
        if status != errSecItemNotFound { try check(status, operation: "delete") }
    }

    func removeAll() throws {
        var query = baseQuery
        query[kSecMatchLimit as String] = kSecMatchLimitAll
        let status = SecItemDelete(query as CFDictionary)
        if status != errSecItemNotFound { try check(status, operation: "delete") }
    }

    private var baseQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service]
    }

    private func check(_ status: OSStatus, operation: String) throws {
        guard status == errSecSuccess else { throw MeterError.message("Could not \(operation) credentials in Keychain (\(status)).") }
    }
}
