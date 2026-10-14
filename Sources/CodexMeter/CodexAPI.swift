import Foundation
import CodexMeterCore
#if os(iOS)
import WidgetKit
#endif

private struct APIErrorEnvelope: Decodable {
    struct Detail: Decodable { let message: String? }
    let errorDescription: String?
    let error: Detail?
    let message: String?
    enum CodingKeys: String, CodingKey {
        case errorDescription = "error_description"
        case error, message
    }
}

actor CodexAPI {
    static let shared = CodexAPI()
    private let credentials: AccountCredentialRepository
    private let auth: AuthAPI
    private let session: URLSession
    private let cacheStore: AccountCacheStore
    private struct PendingRefresh {
        let previous: AuthTokens
        let task: Task<AuthTokens, Error>
    }
    private var refreshTasks: [String: PendingRefresh] = [:]

    init(credentials: AccountCredentialRepository = KeychainTokenStore.repository,
         auth: AuthAPI = .shared, session: URLSession = .shared,
         cacheStore: AccountCacheStore = AccountCacheStore()) {
        self.credentials = credentials
        self.auth = auth
        self.session = session
        self.cacheStore = cacheStore
    }

    func refreshAll(accountId: String) async throws -> (UsageSnapshot, ResetCreditsSnapshot?) {
        var tokens = try await usableTokens(accountId: accountId)
        var response = try await request(url: CodexConstants.usageURL, method: "GET", tokens: tokens)
        if response.status == 401 {
            tokens = try await refreshTokens(tokens)
            response = try await request(url: CodexConstants.usageURL, method: "GET", tokens: tokens)
        }
        try validate(status: response.status, data: response.data, fallback: usageFallback(response.status))
        let usage = try UsageParser.parse(response.data)
        try requireCurrent(tokens)
        cacheStore.save(usage: usage, credits: nil, localAccountId: accountId)

        let credits: ResetCreditsSnapshot?
        do {
            let creditResponse = try await request(url: CodexConstants.resetCreditsURL, method: "GET", tokens: tokens)
            try validate(status: creditResponse.status, data: creditResponse.data, fallback: "Could not load Codex reset credits")
            let parsed = try ResetCreditsParser.parse(creditResponse.data)
            try requireCurrent(tokens)
            cacheStore.save(usage: usage, credits: parsed, localAccountId: accountId)
            credits = parsed
        } catch {
            credits = cacheStore.credits(localAccountId: accountId)
        }
        try requireCurrent(tokens)
        return (usage, credits)
    }

    func consumeBestResetCredit(accountId: String, credits: ResetCreditsSnapshot?) async throws -> String {
        var tokens = try await usableTokens(accountId: accountId)
        var body: [String: Any] = ["redeem_request_id": UUID().uuidString]
        if let id = credits?.preferredCredit?.id, !id.isEmpty { body["credit_id"] = id }
        let payload = try JSONSerialization.data(withJSONObject: body)
        var response = try await request(url: CodexConstants.consumeResetURL, method: "POST", tokens: tokens, body: payload)
        if response.status == 401 {
            tokens = try await refreshTokens(tokens)
            response = try await request(url: CodexConstants.consumeResetURL, method: "POST", tokens: tokens, body: payload)
        }
        try validate(status: response.status, data: response.data, fallback: "Could not apply the Codex reset")
        let object = try JSONSerialization.jsonObject(with: response.data) as? [String: Any]
        return object?["code"] as? String ?? "reset"
    }

    func cachedUsage(accountId: String) -> UsageSnapshot? {
        cacheStore.migrateLegacyGlobalCache(accounts: credentials.loadAll())
        return cacheStore.usage(localAccountId: accountId)
    }

    func cachedCredits(accountId: String) -> ResetCreditsSnapshot? {
        cacheStore.migrateLegacyGlobalCache(accounts: credentials.loadAll())
        return cacheStore.credits(localAccountId: accountId)
    }

    func cacheSnapshots(usage: UsageSnapshot, credits: ResetCreditsSnapshot?, cacheId: String) {
        cacheStore.save(usage: usage, credits: credits, localAccountId: cacheId)
    }

    func removeCache(accountId: String) {
        cacheStore.remove(localAccountId: accountId)
    }

    func publishWidgetSnapshots(_ snapshots: [AccountUsageSnapshot]) {
        let liveIDs = Set(credentials.loadAll().map { "direct:\($0.localAccountId)" })
        let visible = snapshots.filter {
            !$0.id.hasPrefix("direct:") || liveIDs.contains($0.id) || cacheStore.defaults.bool(forKey: "demo-mode")
        }
        guard let data = try? JSONEncoder().encode(visible) else { return }
        cacheStore.defaults.set(data, forKey: SharedStore.accountsKey)
        if let sharedDefaults = cacheStore.sharedDefaults {
            sharedDefaults.set(data, forKey: SharedStore.accountsKey)
            sharedDefaults.synchronize()
        }
        #if os(iOS)
        if let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: SharedStore.suiteName
        ) {
            try? data.write(
                to: container.appendingPathComponent(SharedStore.accountsFileName),
                options: [.atomic, .completeFileProtectionUnlessOpen]
            )
        }
        WidgetCenter.shared.reloadAllTimelines()
        #endif
    }

    private func usableTokens(accountId: String) async throws -> AuthTokens {
        guard var tokens = credentials.load(localAccountId: accountId) else {
            throw MeterError.message("This ChatGPT account is no longer signed in.")
        }
        if tokens.shouldRefresh || tokens.identity == nil {
            tokens = try await refreshTokens(tokens)
        }
        return tokens
    }

    private func request(url: URL, method: String, tokens: AuthTokens, body: Data? = nil) async throws -> (data: Data, status: Int) {
        try requireCurrent(tokens)
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        request.timeoutInterval = 25
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(tokens.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("codex-meter-ios/0.1 (iOS)", forHTTPHeaderField: "User-Agent")
        request.setValue(CodexConstants.originator, forHTTPHeaderField: "originator")
        if !tokens.accountId.isEmpty { request.setValue(tokens.accountId, forHTTPHeaderField: "ChatGPT-Account-Id") }
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw MeterError.message("The server returned an invalid response.") }
        return (data, http.statusCode)
    }

    private func usageFallback(_ status: Int) -> String {
        switch status {
        case 403: "Codex usage access was denied for this account."
        case 404: "The Codex usage endpoint is unavailable or has changed."
        default: "Usage refresh failed (HTTP \(status))."
        }
    }

    private func requireCurrent(_ tokens: AuthTokens) throws {
        guard credentials.load(localAccountId: tokens.localAccountId) == tokens else {
            throw MeterError.message("This ChatGPT session changed while refreshing. Please try again.")
        }
    }

    private func refreshTokens(_ previous: AuthTokens) async throws -> AuthTokens {
        // A concurrent refresh may have already rotated this member's credential.
        guard let current = credentials.load(localAccountId: previous.localAccountId) else {
            throw MeterError.message("This ChatGPT account is no longer signed in.")
        }
        if current != previous { return current }
        if let pending = refreshTasks[previous.localAccountId], pending.previous == previous {
            return try await pending.task.value
        }
        let task = Task { [auth, credentials] in
            let updated = try await auth.refresh(previous)
            try credentials.replace(updated, ifCurrent: previous)
            return updated
        }
        refreshTasks[previous.localAccountId] = PendingRefresh(previous: previous, task: task)
        defer {
            if refreshTasks[previous.localAccountId]?.previous == previous {
                refreshTasks.removeValue(forKey: previous.localAccountId)
            }
        }
        return try await task.value
    }

}

private func validate(response: URLResponse, data: Data, fallback: String) throws {
    guard let http = response as? HTTPURLResponse else { throw MeterError.message(fallback) }
    try validate(status: http.statusCode, data: data, fallback: "\(fallback) (HTTP \(http.statusCode)).")
}

private func validate(status: Int, data: Data, fallback: String) throws {
    guard !(200..<300).contains(status) else { return }
    if let decoded = try? JSONDecoder().decode(APIErrorEnvelope.self, from: data) {
        throw MeterError.message(decoded.errorDescription ?? decoded.error?.message ?? decoded.message ?? fallback)
    }
    if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
       let error = object["error"] as? String, !error.isEmpty {
        throw MeterError.message(error)
    }
    throw MeterError.message(fallback)
}
