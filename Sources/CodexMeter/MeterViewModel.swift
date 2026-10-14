import Foundation
import CodexMeterCore

struct AccountMeterState: Identifiable, Equatable {
    let source: AccountSource
    var sessionGeneration = UUID()
    var email: String
    var nickname: String?
    var proxyName: String?
    var usage: UsageSnapshot?
    var resetCredits: ResetCreditsSnapshot?
    var isRefreshing = false
    var errorMessage: String?
    var lastSuccessfulRefresh: Date?
    var isStale = false
    var sourceLabelOverride: String?

    var id: String { source.stateID }
    var displayName: String {
        let trimmed = nickname?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmed.isEmpty { return trimmed }
        return email.isEmpty ? (proxyName ?? "ChatGPT account") : email
    }
    var resetCount: Int { resetCredits?.availableCount ?? usage?.resetCreditsAvailable ?? 0 }
    var sourceLabel: String? { sourceLabelOverride ?? source.sourceLabel }
}

@MainActor
final class MeterViewModel: ObservableObject {
    @Published private(set) var accounts: [AccountMeterState]
    @Published private(set) var isSigningIn = false
    @Published private(set) var isAddingProxy = false
    @Published private(set) var isDemoMode: Bool
    @Published var errorMessage: String?
    @Published var toastMessage: String?

    var isSignedIn: Bool { !accounts.isEmpty }
    var isRefreshing: Bool { accounts.contains(where: \.isRefreshing) }

    private let oauth = OAuthCoordinator()

    init() {
        let demoMode = UserDefaults.standard.bool(forKey: UsageBackgroundRefresh.demoModeKey)
        isDemoMode = demoMode
        accounts = demoMode ? Self.demoAccounts() : Self.storedAccounts()
        Task {
            if demoMode {
                UsageBackgroundRefresh.cancel()
                await publishWidgetSnapshots()
            } else {
                await loadCachedSnapshots()
                if isSignedIn { _ = await ResetAlertScheduler.requestPermission() }
                let refreshOnLaunch = UserDefaults.standard.object(forKey: "refresh-on-launch") as? Bool ?? true
                if isSignedIn && refreshOnLaunch { await refresh(silently: true) }
                UsageBackgroundRefresh.schedule()
            }
        }
    }

    func setDemoMode(_ enabled: Bool) {
        guard enabled != isDemoMode else { return }
        oauth.cancel(notify: false)
        isSigningIn = false
        UserDefaults.standard.set(enabled, forKey: UsageBackgroundRefresh.demoModeKey)
        isDemoMode = enabled
        accounts = enabled ? Self.demoAccounts() : Self.storedAccounts()
        errorMessage = nil
        Task {
            if enabled {
                UsageBackgroundRefresh.cancel()
                await publishWidgetSnapshots()
                await ResetAlertScheduler.schedule([])
                toastMessage = "Demo mode enabled"
            } else {
                await loadCachedSnapshots()
                await finishRefreshCycle()
                UsageBackgroundRefresh.schedule()
                toastMessage = "Demo mode disabled"
            }
        }
    }

    func signIn(using method: SignInMethod) {
        guard !isDemoMode, !isSigningIn else { return }
        isSigningIn = true
        errorMessage = nil
        oauth.start(using: method) { [weak self] result in
            guard let self else { return }
            self.isSigningIn = false
            switch result {
            case let .success(tokens):
                let source = AccountSource.direct(accountId: tokens.localAccountId)
                if let index = self.accounts.firstIndex(where: { $0.source == source }) {
                    self.accounts[index].sessionGeneration = UUID()
                    self.accounts[index].email = tokens.email
                    self.accounts[index].errorMessage = nil
                    self.accounts[index].isRefreshing = false
                    self.toastMessage = "Account reconnected"
                } else {
                    self.accounts.append(AccountMeterState(
                        source: source, email: tokens.email,
                        nickname: AccountNicknameStore.nickname(for: source.stateID), proxyName: nil
                    ))
                    self.persistAccountOrder()
                    self.toastMessage = "Account added"
                }
                Task {
                    _ = await ResetAlertScheduler.requestPermission()
                    await self.refresh(stateID: source.stateID, silently: false)
                }
            case let .failure(error): self.errorMessage = error.localizedDescription
            }
        }
    }

    func addProxy(setupCode: String) async throws {
        guard !isDemoMode, !isAddingProxy else { return }
        isAddingProxy = true
        defer { isAddingProxy = false }
        let setup = try ProxySetupCode(setupCode)
        let parsed = try await ProxyAPI.shared.test(setup)
        try ProxyCredentialStore.save(token: setup.token, id: setup.id)
        let existing = ProxyProfileStore.loadAll().first { $0.id == setup.id }
        let profile = ProxyProfile(
            id: setup.id,
            name: setup.name,
            baseURL: setup.baseURL,
            email: parsed.email,
            planType: parsed.usage.planType,
            createdAt: existing?.createdAt ?? .now,
            lastSuccessfulRefresh: parsed.usage.fetchedAt
        )
        try ProxyProfileStore.upsert(profile)
        await CodexAPI.shared.cacheSnapshots(usage: parsed.usage, credits: parsed.resetCredits, cacheId: profileSourceID(profile.id))
        let state = AccountMeterState(
            source: .proxy(profileId: profile.id), email: parsed.email,
            nickname: AccountNicknameStore.nickname(for: profileSourceID(profile.id)), proxyName: profile.name,
            usage: parsed.usage, resetCredits: parsed.resetCredits, lastSuccessfulRefresh: parsed.usage.fetchedAt
        )
        if let index = accounts.firstIndex(where: { $0.id == state.id }) { accounts[index] = state }
        else {
            accounts.append(state)
            persistAccountOrder()
        }
        await publishWidgetSnapshots()
        UsageBackgroundRefresh.schedule()
        _ = await ResetAlertScheduler.requestPermission()
        toastMessage = existing == nil ? "CLI proxy added" : "CLI proxy updated"
    }

    func cancelSignIn() { guard isSigningIn else { return }; oauth.cancel() }

    func setNickname(_ nickname: String?, for stateID: String) {
        guard !isDemoMode else { return }
        guard let index = accounts.firstIndex(where: { $0.id == stateID }) else { return }
        AccountNicknameStore.set(nickname, for: stateID)
        accounts[index].nickname = AccountNicknameStore.nickname(for: stateID)
        Task { await publishWidgetSnapshots() }
        toastMessage = accounts.first(where: { $0.id == stateID })?.nickname == nil
            ? "Nickname removed" : "Nickname saved"
    }

    func refresh(silently: Bool = false) async {
        if isDemoMode {
            accounts = Self.demoAccounts()
            await publishWidgetSnapshots()
            if !silently { toastMessage = "Demo data refreshed" }
            return
        }
        let ids = accounts.filter { !$0.isRefreshing }.map(\.id)
        guard !ids.isEmpty else { return }
        for id in ids { setRefreshing(true, stateID: id, clearError: !silently) }
        let inputs = ids.compactMap { id in accounts.first(where: { $0.id == id }).map { RefreshInput(source: $0.source, generation: $0.sessionGeneration) } }
        await withTaskGroup(of: AccountRefreshResult.self) { group in
            for input in inputs { group.addTask { await Self.refreshResult(input) } }
            for await result in group { apply(result) }
        }
        await finishRefreshCycle()
    }

    func refresh(accountId: String, silently: Bool = false) async { await refresh(stateID: accountId, silently: silently) }

    func refresh(stateID: String, silently: Bool = false) async {
        if isDemoMode { await refresh(silently: silently); return }
        guard let index = accounts.firstIndex(where: { $0.id == stateID }), !accounts[index].isRefreshing else { return }
        let input = RefreshInput(source: accounts[index].source, generation: accounts[index].sessionGeneration)
        setRefreshing(true, stateID: stateID, clearError: !silently)
        apply(await Self.refreshResult(input))
        await finishRefreshCycle()
    }

    func useResetCredit(accountId: String) async {
        if isDemoMode { toastMessage = "Reset credits are simulated in demo mode"; return }
        guard let index = accounts.firstIndex(where: { $0.id == accountId }), !accounts[index].isRefreshing else { return }
        let state = accounts[index]
        setRefreshing(true, stateID: state.id, clearError: true)
        do {
            let outcome: String
            switch state.source {
            case let .direct(id):
                outcome = try await CodexAPI.shared.consumeBestResetCredit(accountId: id, credits: state.resetCredits)
            case let .proxy(profileId):
                guard let profile = ProxyProfileStore.loadAll().first(where: { $0.id == profileId }) else {
                    throw MeterError.message("The proxy configuration is missing.")
                }
                outcome = try await ProxyAPI.shared.consumeReset(profile, creditId: state.resetCredits?.preferredCredit?.id)
            }
            toastMessage = resetOutcomeMessage(outcome)
            apply(await Self.refreshResult(RefreshInput(source: state.source, generation: state.sessionGeneration)), detectUnexpectedReset: false)
        } catch { apply(.failure(state.id, state.sessionGeneration, error.localizedDescription)) }
        await finishRefreshCycle()
    }

    func removeAccount(_ stateID: String) {
        guard !isDemoMode else { return }
        guard let state = accounts.first(where: { $0.id == stateID }) else { return }
        oauth.cancel(notify: false)
        isSigningIn = false
        switch state.source {
        case let .direct(accountId):
            let tokens = KeychainTokenStore.load(accountId: accountId)
            do { try KeychainTokenStore.remove(accountId: accountId) }
            catch { errorMessage = error.localizedDescription; return }
            Task { if let tokens { await AuthAPI.shared.revoke(tokens) } }
        case let .proxy(profileId):
            try? ProxyProfileStore.remove(profileId)
            ProxyCredentialStore.remove(id: profileId)
        }
        accounts.removeAll { $0.id == stateID }
        persistAccountOrder()
        AccountNicknameStore.set(nil, for: stateID)
        Task {
            await CodexAPI.shared.removeCache(accountId: cacheID(for: state.source))
            await finishRefreshCycle()
        }
    }

    func signOutAll() {
        guard !isDemoMode else { return }
        let tokens = KeychainTokenStore.loadAll()
        let states = accounts
        oauth.cancel(notify: false)
        isSigningIn = false
        do { try KeychainTokenStore.clearAll() }
        catch { errorMessage = error.localizedDescription; return }
        ProxyCredentialStore.removeAll()
        ProxyProfileStore.removeAll()
        AccountNicknameStore.removeAll()
        AccountOrderStore.removeAll()
        accounts = []
        Task {
            for state in states { await CodexAPI.shared.removeCache(accountId: cacheID(for: state.source)) }
            await finishRefreshCycle()
            for token in tokens { await AuthAPI.shared.revoke(token) }
        }
    }

    func updateResetAlerts() async {
        guard !isDemoMode else { return }
        await ResetAlertScheduler.requestPermissionAndSchedule(alertInputs)
    }

    func moveAccount(_ stateID: String, by offset: Int) {
        guard !isDemoMode,
              let sourceIndex = accounts.firstIndex(where: { $0.id == stateID })
        else { return }
        let destinationIndex = sourceIndex + offset
        guard accounts.indices.contains(destinationIndex) else { return }
        moveAccount(stateID, to: accounts[destinationIndex].id)
    }

    func moveAccount(_ stateID: String, to destinationID: String) {
        guard !isDemoMode, stateID != destinationID,
              let sourceIndex = accounts.firstIndex(where: { $0.id == stateID }),
              let destinationIndex = accounts.firstIndex(where: { $0.id == destinationID })
        else { return }
        let account = accounts.remove(at: sourceIndex)
        accounts.insert(account, at: min(destinationIndex, accounts.endIndex))
        persistAccountOrder()
        Task { await publishWidgetSnapshots() }
        toastMessage = "Account order updated"
    }

    private static func refreshResult(_ input: RefreshInput) async -> AccountRefreshResult {
        do {
            switch input.source {
            case let .direct(accountId):
                let value = try await CodexAPI.shared.refreshAll(accountId: accountId)
                return .success(input.source.stateID, input.generation, value.0, value.1, nil, nil)
            case let .proxy(profileId):
                guard var profile = ProxyProfileStore.loadAll().first(where: { $0.id == profileId }) else {
                    throw MeterError.message("The proxy configuration is missing.")
                }
                let parsed = try await ProxyAPI.shared.refresh(profile)
                profile.email = parsed.email
                profile.planType = parsed.usage.planType
                profile.name = parsed.proxyName.isEmpty ? profile.name : parsed.proxyName
                profile.lastSuccessfulRefresh = parsed.usage.fetchedAt
                try ProxyProfileStore.upsert(profile)
                await CodexAPI.shared.cacheSnapshots(usage: parsed.usage, credits: parsed.resetCredits, cacheId: input.source.stateID)
                return .success(input.source.stateID, input.generation, parsed.usage, parsed.resetCredits, parsed.email, profile.name)
            }
        } catch { return .failure(input.source.stateID, input.generation, error.localizedDescription) }
    }

    private func loadCachedSnapshots() async {
        for state in accounts {
            let cache = cacheID(for: state.source)
            let usage = await CodexAPI.shared.cachedUsage(accountId: cache)
            let credits = await CodexAPI.shared.cachedCredits(accountId: cache)
            guard let index = accounts.firstIndex(where: { $0.id == state.id }) else { continue }
            accounts[index].usage = usage
            accounts[index].resetCredits = credits
        }
        await publishWidgetSnapshots()
    }

    private func apply(_ result: AccountRefreshResult, detectUnexpectedReset: Bool = true) {
        switch result {
        case let .success(id, generation, usage, credits, email, proxyName):
            guard let index = accounts.firstIndex(where: { $0.id == id }),
                  accounts[index].sessionGeneration == generation else { return }
            let previousUsage = accounts[index].usage
            let accountName = accounts[index].displayName
            let accountCount = accounts.count
            accounts[index].usage = usage
            accounts[index].resetCredits = credits
            if let email { accounts[index].email = email }
            if let proxyName { accounts[index].proxyName = proxyName }
            accounts[index].lastSuccessfulRefresh = usage.fetchedAt
            accounts[index].isRefreshing = false
            accounts[index].errorMessage = nil
            accounts[index].isStale = false
            if detectUnexpectedReset {
                Task {
                    await ResetAlertScheduler.notifyIfUnexpectedReset(
                        accountID: id, accountName: accountName, accountCount: accountCount,
                        previous: previousUsage, current: usage
                    )
                }
            }
        case let .failure(id, generation, message):
            guard let index = accounts.firstIndex(where: { $0.id == id }),
                  accounts[index].sessionGeneration == generation else { return }
            accounts[index].isRefreshing = false
            accounts[index].errorMessage = message
            if case .proxy = accounts[index].source {
                accounts[index].isStale = accounts[index].usage != nil
            }
        }
    }

    private func setRefreshing(_ value: Bool, stateID: String, clearError: Bool) {
        guard let index = accounts.firstIndex(where: { $0.id == stateID }) else { return }
        accounts[index].isRefreshing = value
        if clearError { accounts[index].errorMessage = nil }
    }

    private func finishRefreshCycle() async {
        await publishWidgetSnapshots()
        if !isDemoMode {
            await ResetAlertScheduler.schedule(alertInputs)
            UsageBackgroundRefresh.schedule()
        }
    }

    private var alertInputs: [ResetAlertScheduler.AccountUsage] {
        accounts.map { ($0.id, $0.displayName, $0.usage) }
    }

    private func persistAccountOrder() {
        guard !isDemoMode else { return }
        AccountOrderStore.set(accounts.map(\.id))
    }

    private func publishWidgetSnapshots() async {
        let snapshots = accounts.map {
            AccountUsageSnapshot(
                id: $0.id, email: $0.email, nickname: $0.nickname,
                usage: $0.usage, sourceLabel: $0.sourceLabel,
                isStale: $0.isStale, lastSuccessfulAt: $0.lastSuccessfulRefresh
            )
        }
        await CodexAPI.shared.publishWidgetSnapshots(snapshots)
    }

    private func resetOutcomeMessage(_ outcome: String) -> String {
        switch outcome {
        case "reset": "Usage window reset"
        case "nothingToReset": "Nothing is eligible to reset"
        case "noCredit": "No reset credit is available"
        case "alreadyRedeemed": "Reset was already applied"
        default: outcome.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    private static func storedAccounts() -> [AccountMeterState] {
        let direct = KeychainTokenStore.loadAll().map {
            let source = AccountSource.direct(accountId: $0.localAccountId)
            return AccountMeterState(
                source: source, email: $0.email,
                nickname: AccountNicknameStore.nickname(for: source.stateID), proxyName: nil
            )
        }
        let proxies = ProxyProfileStore.loadAll().map {
            let source = AccountSource.proxy(profileId: $0.id)
            return AccountMeterState(
                source: source, email: $0.email,
                nickname: AccountNicknameStore.nickname(for: source.stateID), proxyName: $0.name,
                lastSuccessfulRefresh: $0.lastSuccessfulRefresh
            )
        }
        return AccountOrderStore.ordered(direct + proxies, id: \.id)
    }

    private static func demoAccounts(now: Date = .now) -> [AccountMeterState] {
        func window(used: Int, duration: Int, resetsIn: Int) -> UsageWindow {
            UsageWindow(
                usedPercent: used, windowSeconds: duration, resetAfterSeconds: resetsIn,
                resetAtEpochSeconds: Int(now.addingTimeInterval(TimeInterval(resetsIn)).timeIntervalSince1970)
            )
        }
        func usage(fiveUsed: Int?, weeklyUsed: Int, weeklyResetsIn: Int) -> UsageSnapshot {
            UsageSnapshot(
                planType: "plus", allowed: true, limitReached: false,
                fiveHour: fiveUsed.map { window(used: $0, duration: 18_000, resetsIn: 7_800) },
                weekly: window(used: weeklyUsed, duration: 604_800, resetsIn: weeklyResetsIn),
                resetCreditsAvailable: 2, fetchedAt: now
            )
        }
        return [
            AccountMeterState(
                source: .direct(accountId: "demo-review"), email: "reviewer@example.com",
                nickname: "Review account", proxyName: nil,
                usage: usage(fiveUsed: 28, weeklyUsed: 54, weeklyResetsIn: 259_200),
                lastSuccessfulRefresh: now, sourceLabelOverride: "DEMO"
            ),
            AccountMeterState(
                source: .direct(accountId: "demo-studio"), email: "studio@example.com",
                nickname: "Studio Mac", proxyName: nil,
                usage: usage(fiveUsed: nil, weeklyUsed: 19, weeklyResetsIn: 432_000),
                lastSuccessfulRefresh: now, sourceLabelOverride: "DEMO"
            )
        ]
    }
}

private struct RefreshInput: Sendable { let source: AccountSource; let generation: UUID }

private enum AccountRefreshResult: Sendable {
    case success(String, UUID, UsageSnapshot, ResetCreditsSnapshot?, String?, String?)
    case failure(String, UUID, String)
}

private func cacheID(for source: AccountSource) -> String {
    switch source { case let .direct(id): id; case .proxy: source.stateID }
}

private func profileSourceID(_ id: UUID) -> String { AccountSource.proxy(profileId: id).stateID }
