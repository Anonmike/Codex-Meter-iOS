import BackgroundTasks
import Foundation
import CodexMeterCore

enum UsageBackgroundRefresh {
    static let identifier = "com.picklemike.codexmeter.proxy-refresh"
    static let enabledKey = "background-proxy-refresh"
    static let intervalKey = "background-refresh-minutes"
    static let demoModeKey = "demo-mode"
    static let lastScheduledKey = "background-refresh-last-scheduled"
    static let lastAttemptKey = "background-refresh-last-attempt"
    static let scheduleErrorKey = "background-refresh-schedule-error"
    static let allowedIntervals = [5, 10, 15, 30, 60, 120]

    static var intervalMinutes: Int {
        let stored = UserDefaults.standard.integer(forKey: intervalKey)
        return allowedIntervals.contains(stored) ? stored : 30
    }

    static func schedule() {
        cancel()
        let enabled = UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true
        let hasAccounts = !KeychainTokenStore.loadAll().isEmpty || !ProxyProfileStore.loadAll().isEmpty
        guard enabled, !UserDefaults.standard.bool(forKey: demoModeKey), hasAccounts else { return }

        let request = BGAppRefreshTaskRequest(identifier: identifier)
        request.earliestBeginDate = Date().addingTimeInterval(TimeInterval(intervalMinutes * 60))
        do {
            try BGTaskScheduler.shared.submit(request)
            UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: lastScheduledKey)
            UserDefaults.standard.removeObject(forKey: scheduleErrorKey)
        } catch {
            UserDefaults.standard.set(error.localizedDescription, forKey: scheduleErrorKey)
        }
    }

    static func cancel() {
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: identifier)
    }

    static func run() async {
        defer { schedule() }
        let enabled = UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true
        guard enabled, !UserDefaults.standard.bool(forKey: demoModeKey), !Task.isCancelled else { return }
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: lastAttemptKey)

        let tokens = KeychainTokenStore.loadAll()
        let profiles = ProxyProfileStore.loadAll()
        let accountCount = tokens.count + profiles.count
        var refreshedDirectAccounts = Set<String>()
        await withTaskGroup(of: (String, Bool).self) { group in
            for token in tokens {
                group.addTask {
                    do {
                        let previous = await CodexAPI.shared.cachedUsage(accountId: token.localAccountId)
                        let refreshed = try await CodexAPI.shared.refreshAll(accountId: token.localAccountId)
                        let stateID = AccountSource.direct(accountId: token.localAccountId).stateID
                        await ResetAlertScheduler.notifyIfUnexpectedReset(
                            accountID: stateID,
                            accountName: AccountNicknameStore.nickname(for: stateID) ?? token.email,
                            accountCount: accountCount,
                            previous: previous,
                            current: refreshed.0
                        )
                        return (token.localAccountId, true)
                    } catch {
                        return (token.localAccountId, false)
                    }
                }
            }
            for await (accountID, succeeded) in group where succeeded && !Task.isCancelled {
                refreshedDirectAccounts.insert(accountID)
            }
        }

        var refreshedProxies: [UUID: ParsedProxySnapshot] = [:]
        await withTaskGroup(of: (UUID, ParsedProxySnapshot?).self) { group in
            for profile in profiles {
                group.addTask {
                    do {
                        let stateID = AccountSource.proxy(profileId: profile.id).stateID
                        let previous = await CodexAPI.shared.cachedUsage(accountId: stateID)
                        let snapshot = try await ProxyAPI.shared.refresh(profile)
                        await ResetAlertScheduler.notifyIfUnexpectedReset(
                            accountID: stateID,
                            accountName: AccountNicknameStore.nickname(for: stateID) ?? profile.email,
                            accountCount: accountCount,
                            previous: previous,
                            current: snapshot.usage
                        )
                        return (profile.id, snapshot)
                    }
                    catch { return (profile.id, nil) }
                }
            }
            for await (id, snapshot) in group where !Task.isCancelled {
                if let snapshot { refreshedProxies[id] = snapshot }
            }
        }

        for var profile in profiles {
            if let snapshot = refreshedProxies[profile.id] {
                profile.email = snapshot.email
                profile.name = snapshot.proxyName.isEmpty ? profile.name : snapshot.proxyName
                profile.planType = snapshot.usage.planType
                profile.lastSuccessfulRefresh = snapshot.usage.fetchedAt
                try? ProxyProfileStore.upsert(profile)
                await CodexAPI.shared.cacheSnapshots(
                    usage: snapshot.usage, credits: snapshot.resetCredits,
                    cacheId: AccountSource.proxy(profileId: profile.id).stateID
                )
            }
        }

        var widgetAccounts: [AccountUsageSnapshot] = []
        for token in KeychainTokenStore.loadAll() {
            let stateID = AccountSource.direct(accountId: token.localAccountId).stateID
            let usage = await CodexAPI.shared.cachedUsage(accountId: token.localAccountId)
            widgetAccounts.append(AccountUsageSnapshot(
                id: stateID, email: token.email,
                nickname: AccountNicknameStore.nickname(for: stateID), usage: usage,
                isStale: usage != nil && !refreshedDirectAccounts.contains(token.localAccountId),
                lastSuccessfulAt: usage?.fetchedAt
            ))
        }

        for profile in ProxyProfileStore.loadAll() {
            let stateID = AccountSource.proxy(profileId: profile.id).stateID
            let usage = await CodexAPI.shared.cachedUsage(accountId: stateID)
            widgetAccounts.append(AccountUsageSnapshot(
                id: stateID, email: profile.email,
                nickname: AccountNicknameStore.nickname(for: stateID), usage: usage,
                sourceLabel: "CLI PROXY", isStale: usage != nil && refreshedProxies[profile.id] == nil,
                lastSuccessfulAt: profile.lastSuccessfulRefresh
            ))
        }

        widgetAccounts = AccountOrderStore.ordered(widgetAccounts, id: \.id)
        await CodexAPI.shared.publishWidgetSnapshots(widgetAccounts)
        await ResetAlertScheduler.schedule(widgetAccounts.map { ($0.id, $0.displayName, $0.usage) })
    }
}
