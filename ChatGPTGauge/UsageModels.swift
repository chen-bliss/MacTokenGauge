import Foundation

enum UsageSource: String, Equatable, Sendable {
    case live
    case localLog
}

enum UsageValue: Equatable, Sendable {
    case quota(usedPercent: Double)
    case amount(value: Decimal, currency: String)
}

struct UsageWindow: Equatable, Sendable, Identifiable {
    var id: String
    var title: String
    var value: UsageValue
    var resetAt: Date?
    var windowSeconds: TimeInterval?

    init(id: String, title: String, usedPercent: Double, resetAt: Date?, windowSeconds: TimeInterval?) {
        self.id = id
        self.title = title
        self.value = .quota(usedPercent: min(100, max(0, usedPercent)))
        self.resetAt = resetAt
        self.windowSeconds = windowSeconds
    }

    init(id: String, title: String, amount: Decimal, currency: String, resetAt: Date?, windowSeconds: TimeInterval?) {
        self.id = id
        self.title = title
        self.value = .amount(value: amount, currency: currency)
        self.resetAt = resetAt
        self.windowSeconds = windowSeconds
    }

    var isQuota: Bool {
        if case .quota = value { return true }
        return false
    }

    // Percentage consumers must check isQuota first.
    var usedPercent: Double {
        if case .quota(let used) = value { return used }
        return 0
    }

    var remainingPercent: Double { min(100, max(0, 100 - usedPercent)) }

    var detail: String? {
        guard case .amount(let amount, let currency) = value else { return nil }
        let formatter = NumberFormatter()
        formatter.locale = L10n.language.resolved.locale
        formatter.numberStyle = .currency
        formatter.currencyCode = currency
        return formatter.string(from: amount as NSDecimalNumber)
    }

    var displayValue: String { detail ?? "\(Int(remainingPercent.rounded()))%" }
}

struct UsageSnapshot: Equatable, Sendable {
    var planType: String?
    var windows: [UsageWindow]
    var creditsBalance: String?
    var source: UsageSource
    var capturedAt: Date
}

enum AccountState: String, Equatable, Sendable {
    case loading, current, stale, local, failed, paused
}

struct ProviderAccount: Identifiable, Equatable, Sendable {
    var id: String
    var name: String
    var menuTitle: String
    var plan: String?
    var accountLabel: String?
    var windows: [UsageWindow]
    var status: String
    var capturedAt: Date?
    var creditsBalance: String?
    var note: String?
    var origin: UsageSource = .live
    var state: AccountState = .current
    var attemptedAt: Date? = nil
    var accountIdentity: String? = nil
    var retryAfter: Date? = nil

    var headlineWindows: [UsageWindow] {
        id == "chatgpt" ? windows.filter { !$0.id.hasPrefix("extra-") } : windows
    }

    var canAlert: Bool { state == .current && origin == .live && !windows.isEmpty }
    var showsLiveQuota: Bool { state == .current && origin == .live }

    var stateLabel: String {
        switch state {
        case .loading: return L10n.s(.reading)
        case .current: return L10n.s(.official)
        case .stale: return L10n.s(.staleReading)
        case .local: return L10n.s(.localCodex)
        case .failed: return L10n.s(.unavailable)
        case .paused: return L10n.s(.pausedUpdates)
        }
    }

    /// Keep the last successful values, while recording every failed attempt.
    static func merging(_ fresh: ProviderAccount, previous: ProviderAccount?) -> ProviderAccount {
        guard let previous else { return fresh }
        if fresh.accountIdentity != previous.accountIdentity { return fresh }
        if previous.windows.isEmpty { return fresh }
        if fresh.windows.isEmpty || (fresh.origin == .localLog && previous.origin == .live) {
            var kept = previous
            kept.state = .stale
            kept.status = fresh.status
            kept.attemptedAt = fresh.attemptedAt
            kept.retryAfter = fresh.retryAfter
            return kept
        }
        return fresh
    }

    static let placeholders: [ProviderAccount] = [
        ProviderAccount(id: "chatgpt", name: "ChatGPT", menuTitle: "GPT", plan: nil, accountLabel: nil, windows: [], status: L10n.s(.reading), capturedAt: nil, creditsBalance: nil, note: nil, state: .loading),
        ProviderAccount(id: "cursor", name: "Cursor", menuTitle: "Cursor", plan: nil, accountLabel: nil, windows: [], status: L10n.s(.reading), capturedAt: nil, creditsBalance: nil, note: nil, state: .loading),
        ProviderAccount(id: "claude", name: "Claude", menuTitle: "Claude", plan: nil, accountLabel: nil, windows: [], status: L10n.s(.reading), capturedAt: nil, creditsBalance: nil, note: nil, state: .loading)
    ]
}

enum BatteryMark: String, CaseIterable, Identifiable {
    case icon
    case percent

    var id: String { rawValue }

    var title: String {
        switch self {
        case .icon: return L10n.s(.batteryIconOnly)
        case .percent: return L10n.s(.batteryPercentOnly)
        }
    }
}

struct BatteryReading: Equatable, Sendable {
    var percent: Int
    var charging: Bool
}

enum UsageFormatting {
    static func headline(_ windows: [UsageWindow]) -> UsageWindow? {
        let quotas = windows.filter(\.isQuota)
        guard let minimum = quotas.map(\.remainingPercent).min() else { return nil }
        return quotas.filter { $0.remainingPercent <= minimum + 5 }.min { lhs, rhs in
            let left = lhs.windowSeconds ?? .greatestFiniteMagnitude
            let right = rhs.windowSeconds ?? .greatestFiniteMagnitude
            if left != right { return left < right }
            if lhs.remainingPercent != rhs.remainingPercent { return lhs.remainingPercent < rhs.remainingPercent }
            return lhs.id < rhs.id
        }
    }

    static func menuText(_ window: UsageWindow, now: Date) -> String {
        guard let resetAt = window.resetAt else { return window.displayValue }
        return "\(window.displayValue) \(shortCountdown(until: resetAt, now: now))"
    }

    static func shortCountdown(until date: Date, now: Date) -> String {
        let seconds = Int(date.timeIntervalSince(now))
        if seconds <= 0 { return L10n.s(.resetSoon) }
        let days = seconds / 86_400
        let hours = (seconds % 86_400) / 3_600
        let minutes = (seconds % 3_600) / 60
        if days > 0 { return L10n.f(.shortDH, days, hours) }
        if hours > 0 { return L10n.f(.shortHM, hours, minutes) }
        return L10n.f(.shortM, max(minutes, 1))
    }

    static func longCountdown(until date: Date, now: Date) -> String {
        let seconds = Int(date.timeIntervalSince(now))
        if seconds <= 0 { return L10n.s(.resetSoon) }
        let days = seconds / 86_400
        let hours = (seconds % 86_400) / 3_600
        let minutes = (seconds % 3_600) / 60
        if days > 0 { return L10n.f(.longDH, days, hours) }
        if hours > 0 { return L10n.f(.longHM, hours, minutes) }
        return L10n.f(.longM, max(minutes, 1))
    }

    static func clock(_ date: Date, now: Date) -> String {
        let calendar = Calendar.current
        let time = DateFormatter()
        time.locale = L10n.language.resolved.locale
        time.setLocalizedDateFormatFromTemplate("Hm")
        let clock = time.string(from: date)
        if calendar.isDateInToday(date) { return L10n.f(.todayAt, clock) }
        if calendar.isDateInTomorrow(date) { return L10n.f(.tomorrowAt, clock) }
        let day = DateFormatter()
        day.locale = L10n.language.resolved.locale
        day.setLocalizedDateFormatFromTemplate("MMMd")
        return L10n.f(.dateAt, day.string(from: date), clock)
    }

    static func updatedAgo(_ date: Date, now: Date) -> String {
        let seconds = Int(now.timeIntervalSince(date))
        if seconds < 15 { return L10n.s(.justNow) }
        if seconds < 60 { return L10n.f(.secsAgo, seconds) }
        if seconds < 3_600 { return L10n.f(.minsAgo, seconds / 60) }
        if seconds < 86_400 { return L10n.f(.hoursAgo, seconds / 3_600) }
        return L10n.f(.daysAgo, seconds / 86_400)
    }

    static func planName(_ raw: String?, fallback: String) -> String {
        switch raw?.lowercased() {
        case "plus": return "Plus"
        case "pro": return "Pro"
        case "pro_plus", "pro+": return "Pro+"
        case "prolite", "pro_lite": return "Pro"
        case "ultra": return "Ultra"
        case "team", "business": return "Team"
        case "enterprise": return "Enterprise"
        case "free": return "Free"
        case "go": return "Go"
        case nil, "": return fallback
        default: return raw ?? fallback
        }
    }

    static func tooltip(for snapshot: UsageSnapshot, now: Date) -> String {
        let lines = snapshot.windows.map { window -> String in
            let name = L10n.windowTitle(window)
            if let detail = window.detail { return "\(name): \(detail)" }
            let remain = L10n.f(.helpLeft, name, Int(window.remainingPercent.rounded()))
            guard let resetAt = window.resetAt else { return remain }
            return L10n.f(.helpLeftReset, name, Int(window.remainingPercent.rounded()), clock(resetAt, now: now))
        }
        return lines.joined(separator: "。")
    }
}
