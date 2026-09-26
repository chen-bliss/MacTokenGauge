import Foundation

enum UsageSource: String, Equatable, Sendable {
    case live
    case localLog
}

struct UsageWindow: Equatable, Sendable, Identifiable {
    var id: String
    var title: String
    var usedPercent: Double
    var resetAt: Date?
    var windowSeconds: TimeInterval?

    var remainingPercent: Double {
        min(100, max(0, 100 - usedPercent))
    }
}

struct UsageSnapshot: Equatable, Sendable {
    var planType: String?
    var windows: [UsageWindow]
    var creditsBalance: String?
    var source: UsageSource
    var capturedAt: Date
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

    static let placeholders: [ProviderAccount] = [
        ProviderAccount(id: "chatgpt", name: "ChatGPT", menuTitle: "GPT", plan: nil, accountLabel: nil, windows: [], status: L10n.s(.reading), capturedAt: nil, creditsBalance: nil, note: nil),
        ProviderAccount(id: "cursor", name: "Cursor", menuTitle: "Cursor", plan: nil, accountLabel: nil, windows: [], status: L10n.s(.reading), capturedAt: nil, creditsBalance: nil, note: nil),
        ProviderAccount(id: "claude", name: "Claude", menuTitle: "Claude", plan: nil, accountLabel: nil, windows: [], status: L10n.s(.reading), capturedAt: nil, creditsBalance: nil, note: nil)
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
        guard !windows.isEmpty else { return nil }
        return windows.min { lhs, rhs in
            if abs(lhs.remainingPercent - rhs.remainingPercent) > 5 {
                return lhs.remainingPercent < rhs.remainingPercent
            }
            let lhsLength = lhs.windowSeconds ?? .greatestFiniteMagnitude
            let rhsLength = rhs.windowSeconds ?? .greatestFiniteMagnitude
            return lhsLength < rhsLength
        }
    }

    static func menuText(_ window: UsageWindow, now: Date) -> String {
        let percent = "\(Int(window.remainingPercent.rounded()))%"
        guard let resetAt = window.resetAt else { return percent }
        return "\(percent) \(shortCountdown(until: resetAt, now: now))"
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
            let remain = L10n.f(.helpLeft, name, Int(window.remainingPercent.rounded()))
            guard let resetAt = window.resetAt else { return remain }
            return L10n.f(.helpLeftReset, name, Int(window.remainingPercent.rounded()), clock(resetAt, now: now))
        }
        return lines.joined(separator: "。")
    }
}
