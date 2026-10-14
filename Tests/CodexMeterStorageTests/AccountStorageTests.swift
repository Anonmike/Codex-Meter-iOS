import CodexMeterCore
@testable import CodexMeterStorage
import Foundation
import Security
import TestSupport
import XCTest

final class AccountStorageTests: XCTestCase, @unchecked Sendable {
    func testRealKeychainUsesSeparateItemsAndKeepsOtherMemberOnLogout() throws {
        // This unique test service never reads the production application's service.
        let storage = KeychainCredentialStorage(service: "codex-meter.synthetic-tests.\(UUID())")
        defer { try? storage.removeAll() }
        let repository = AccountCredentialRepository(storage: storage)
        let a = try repository.connect(tokens())
        let b = try repository.connect(tokens("user-b"))
        let items = try storage.items()
        XCTAssertEqual(Set(items.keys), Set([AccountCredentialRepository.prefix + a.localAccountId,
                                            AccountCredentialRepository.prefix + b.localAccountId]))
        for token in [a, b] {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: storage.service,
                kSecAttrAccount as String: AccountCredentialRepository.prefix + token.localAccountId,
                kSecReturnAttributes as String: true
            ]
            var result: CFTypeRef?
            XCTAssertEqual(SecItemCopyMatching(query as CFDictionary, &result), errSecSuccess)
            let attributes = try XCTUnwrap(result as? [String: Any])
            XCTAssertEqual(attributes[kSecAttrAccount as String] as? String, AccountCredentialRepository.prefix + token.localAccountId)
            #if os(iOS)
            XCTAssertEqual(attributes[kSecAttrAccessible as String] as? String, kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)
            #endif
        }
        try repository.remove(localAccountId: a.localAccountId)
        XCTAssertEqual(repository.loadAll(), [b])
    }

    func testConcurrentRefreshKeepsWorkspaceHeaderCredentialsCachesAndWidgetsIndependent() async throws {
        let repository = AccountCredentialRepository(storage: MemoryCredentials())
        let a = try repository.connect(tokens(expiresAt: .distantPast))
        let b = try repository.connect(tokens("user-b", expiresAt: .distantPast))
        let suite = "codex-meter.synthetic-tests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let cache = AccountCacheStore(defaults: defaults, sharedDefaults: nil)
        let session = MockHTTP.session { request in
            if request.url == CodexConstants.tokenURL {
                let body = try JSONSerialization.jsonObject(with: requestBody(request)) as! [String: String]
                let refresh = try XCTUnwrap(body["refresh_token"])
                XCTAssertTrue(refresh == a.refreshToken || refresh == b.refreshToken)
                return (200, try JSONSerialization.data(withJSONObject: ["access_token": refresh + "-updated", "refresh_token": refresh + "-rotated"]))
            }
            XCTAssertEqual(request.httpMethod, "GET") // No test can redeem a reset credit.
            XCTAssertEqual(request.value(forHTTPHeaderField: "ChatGPT-Account-Id"), "business-workspace")
            let bearer = request.value(forHTTPHeaderField: "Authorization") ?? ""
            XCTAssertTrue(bearer.contains(a.refreshToken) || bearer.contains(b.refreshToken))
            if request.url == CodexConstants.resetCreditsURL { return (200, Data("{\"available_count\":0,\"credits\":[]}".utf8)) }
            XCTAssertEqual(request.url, CodexConstants.usageURL)
            let used = bearer.contains(a.refreshToken) ? 20 : 70
            return (200, usageData(used))
        }
        defer { session.invalidateAndCancel() }
        let api = CodexAPI(credentials: repository, auth: AuthAPI(session: session), session: session, cacheStore: cache)
        async let aRefresh = api.refreshAll(accountId: a.localAccountId)
        async let bRefresh = api.refreshAll(accountId: b.localAccountId)
        let aUsage = try await aRefresh.0
        let bUsage = try await bRefresh.0
        XCTAssertEqual(aUsage.fiveHour?.usedPercent, 20)
        XCTAssertEqual(bUsage.fiveHour?.usedPercent, 70)
        XCTAssertEqual(cache.usage(localAccountId: a.localAccountId)?.fiveHour?.usedPercent, 20)
        XCTAssertEqual(cache.usage(localAccountId: b.localAccountId)?.fiveHour?.usedPercent, 70)
        let snapshots = [a, b].enumerated().map { index, token in
            AccountUsageSnapshot(id: "direct:\(token.localAccountId)", email: token.email, usage: index == 0 ? aUsage : bUsage)
        }
        await api.publishWidgetSnapshots(snapshots)
        let data = try XCTUnwrap(defaults.data(forKey: SharedStore.accountsKey))
        let widgets = try JSONDecoder().decode([AccountUsageSnapshot].self, from: data)
        XCTAssertEqual(Set(widgets.map(\.id)).count, 2)
        XCTAssertEqual(widgets.map { $0.usage?.fiveHour?.usedPercent }, [20, 70])
        let json = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(json.contains("synthetic-access"))
        XCTAssertFalse(json.contains("synthetic-refresh"))
        XCTAssertFalse(json.contains("user-a"))
        try repository.remove(localAccountId: a.localAccountId)
        await api.removeCache(accountId: a.localAccountId)
        await api.publishWidgetSnapshots(snapshots) // Stale background input must exclude logged-out A.
        XCTAssertNil(cache.usage(localAccountId: a.localAccountId))
        XCTAssertEqual(cache.usage(localAccountId: b.localAccountId), bUsage)
        let remaining = try JSONDecoder().decode([AccountUsageSnapshot].self, from: XCTUnwrap(defaults.data(forKey: SharedStore.accountsKey)))
        XCTAssertEqual(remaining.map(\.id), ["direct:\(b.localAccountId)"])
        XCTAssertEqual(repository.load(localAccountId: b.localAccountId)?.refreshToken, b.refreshToken + "-rotated")
    }

    func testLogoutDuringRefreshCannotRestoreCredentialsCacheOrWidget() async throws {
        let repository = AccountCredentialRepository(storage: MemoryCredentials())
        let a = try repository.connect(tokens(expiresAt: .distantPast))
        let b = try repository.connect(tokens("user-b"))
        let suite = "codex-meter.synthetic-tests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let cache = AccountCacheStore(defaults: defaults, sharedDefaults: nil)
        let started = expectation(description: "Synthetic refresh is in flight")
        let gate = DispatchSemaphore(value: 0)
        let session = MockHTTP.session { request in
            XCTAssertEqual(request.url, CodexConstants.tokenURL)
            started.fulfill()
            XCTAssertEqual(gate.wait(timeout: .now() + 10), .success)
            return (200, Data("{\"access_token\":\"synthetic-late-access\",\"refresh_token\":\"synthetic-late-refresh\"}".utf8))
        }
        defer { gate.signal(); session.invalidateAndCancel() }
        let api = CodexAPI(credentials: repository, auth: AuthAPI(session: session), session: session, cacheStore: cache)
        let pending = Task { try await api.refreshAll(accountId: a.localAccountId) }
        await fulfillment(of: [started], timeout: 5)
        try repository.remove(localAccountId: a.localAccountId)
        await api.removeCache(accountId: a.localAccountId)
        gate.signal()
        do { _ = try await pending.value; XCTFail("Logged-out credential was restored") }
        catch {}
        XCTAssertNil(repository.load(localAccountId: a.localAccountId))
        XCTAssertEqual(repository.load(localAccountId: b.localAccountId), b)
        XCTAssertNil(cache.usage(localAccountId: a.localAccountId))
        await api.publishWidgetSnapshots([AccountUsageSnapshot(id: "direct:\(a.localAccountId)", email: a.email, usage: nil)])
        let widgets = try JSONDecoder().decode([AccountUsageSnapshot].self, from: XCTUnwrap(defaults.data(forKey: SharedStore.accountsKey)))
        XCTAssertTrue(widgets.isEmpty)
    }

    func testConcurrentRefreshOfSameMemberRotatesCredentialsOnce() async throws {
        let repository = AccountCredentialRepository(storage: MemoryCredentials())
        let a = try repository.connect(tokens(expiresAt: .distantPast))
        let counter = RefreshCounter()
        let suite = "codex-meter.synthetic-tests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let session = MockHTTP.session { request in
            if request.url == CodexConstants.tokenURL {
                counter.increment()
                Thread.sleep(forTimeInterval: 0.1)
                return (200, Data("{\"access_token\":\"synthetic-new-access\",\"refresh_token\":\"synthetic-new-refresh\"}".utf8))
            }
            XCTAssertEqual(request.httpMethod, "GET")
            if request.url == CodexConstants.resetCreditsURL { return (200, Data("{\"available_count\":0,\"credits\":[]}".utf8)) }
            return (200, usageData(20))
        }
        defer { session.invalidateAndCancel() }
        let api = CodexAPI(credentials: repository, auth: AuthAPI(session: session), session: session,
                           cacheStore: AccountCacheStore(defaults: defaults, sharedDefaults: nil))
        async let first = api.refreshAll(accountId: a.localAccountId)
        async let second = api.refreshAll(accountId: a.localAccountId)
        _ = try await (first, second)
        XCTAssertEqual(counter.value, 1)
        XCTAssertEqual(repository.load(localAccountId: a.localAccountId)?.refreshToken, "synthetic-new-refresh")
    }

    func testV1AndV2CacheMigrationCannotLeakIntoNewBusinessMember() throws {
        let suite = "codex-meter.synthetic-tests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let cache = AccountCacheStore(defaults: defaults, sharedDefaults: nil)
        let usage = try UsageParser.parse(usageData(20))
        let legacy = try JSONDecoder().decode(AuthTokens.self, from: legacyData(tokens())).owningLegacyGlobalCache()
        let b = tokens("user-b")
        defaults.set(try JSONEncoder().encode(usage), forKey: SharedStore.usageKey)
        cache.migrateLegacyGlobalCache(accounts: [legacy, b])
        XCTAssertNil(cache.usage(localAccountId: b.localAccountId))
        XCTAssertNotNil(defaults.data(forKey: SharedStore.usageKey))
        cache.migrateLegacyGlobalCache(accounts: [legacy])
        XCTAssertEqual(cache.usage(localAccountId: legacy.localAccountId), usage)
        XCTAssertNil(defaults.data(forKey: SharedStore.usageKey))
        XCTAssertNil(cache.usage(localAccountId: b.localAccountId))
        // v2 IDs are retained, so caches and metadata already keyed by them survive.
        let migrated = tokens(localID: legacy.localAccountId)
        XCTAssertEqual(cache.usage(localAccountId: migrated.localAccountId), usage)
    }
}

private final class RefreshCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
    func increment() { lock.lock(); defer { lock.unlock() }; count += 1 }
}

private func usageData(_ used: Int) -> Data {
    Data("""
    {"plan_type":"business","rate_limit":{"primary_window":{"used_percent":\(used),"limit_window_seconds":18000,"reset_after_seconds":3600,"reset_at":1900000000}}}
    """.utf8)
}
