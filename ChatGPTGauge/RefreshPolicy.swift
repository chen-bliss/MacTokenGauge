import Foundation

/// Pure scheduling rules; UsageMonitor owns only timer and task lifetimes.
enum RefreshPolicy {
    static func interval(minutes: Double, powerSaver: Bool) -> TimeInterval {
        let chosen = max(60, minutes * 60)
        return powerSaver ? max(chosen * 3, 15 * 60) : chosen
    }

    static func nextDelay(accounts: [ProviderAccount], enabled: Set<String>, interval: TimeInterval, now: Date) -> TimeInterval {
        let delays = enabled.map { id -> TimeInterval in
            guard let account = accounts.first(where: { $0.id == id }) else { return interval }
            if let retry = account.retryAfter, retry > now { return retry.timeIntervalSince(now) }
            if let resume = resumeAt(account, now: now), resume > now { return resume.timeIntervalSince(now) }
            return interval
        }
        return min(max(delays.min() ?? interval, 30), 24 * 60 * 60)
    }

    static func shouldFetch(account: ProviderAccount?, enabled: Bool, force: Bool, now: Date) -> Bool {
        guard enabled else { return false }
        if let retry = account?.retryAfter, retry > now { return false }
        if force { return true }
        guard let account, !account.windows.isEmpty else { return true }
        return resumeAt(account, now: now).map { $0 <= now } ?? true
    }

    static func resumeAt(_ account: ProviderAccount, now: Date) -> Date? {
        guard account.showsLiveQuota else { return nil }
        let gates = gatingWindows(account)
        guard !gates.isEmpty, gates.allSatisfy({ $0.isQuota && $0.remainingPercent <= 0.5 }),
              gates.allSatisfy({ $0.resetAt != nil }),
              let earliest = gates.compactMap(\.resetAt).filter({ $0 > now }).min() else { return nil }
        return earliest.addingTimeInterval(20)
    }

    private static func gatingWindows(_ account: ProviderAccount) -> [UsageWindow] {
        switch account.id {
        case "chatgpt": return account.windows.filter { $0.id == "primary" }
        case "claude": return account.windows.filter { $0.id == "five_hour" }
        case "cursor":
            if let extra = account.windows.first(where: { $0.id == "cursor-ondemand" }),
               !extra.isQuota || extra.remainingPercent > 0.5 { return [] }
            return account.windows.filter { ["cursor-total", "cursor-auto", "cursor-api"].contains($0.id) }
        default: return []
        }
    }
}
