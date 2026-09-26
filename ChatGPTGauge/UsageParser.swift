import Foundation

enum UsageParser {
    static func parse(data: Data, source: UsageSource, capturedAt: Date) -> UsageSnapshot? {
        guard let json = try? JSONSerialization.jsonObject(with: data) else { return nil }
        var best: UsageSnapshot?
        collect(json, inheritedPlan: nil, inheritedCredits: nil, capturedAt: capturedAt, source: source, best: &best)
        return best
    }

    static func selfCheck() {
        let capturedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let live = """
        {"plan_type":"plus","rate_limit":{"primary_window":{"used_percent":32,"limit_window_seconds":18000,"reset_at":1700003600},"secondary_window":{"used_percent":18.5,"limit_window_seconds":604800,"reset_at":1700600000}},"credits":{"balance":"4.50"}}
        """.data(using: .utf8)!
        let liveSnapshot = parse(data: live, source: .live, capturedAt: capturedAt)
        precondition(liveSnapshot?.planType == "plus")
        precondition(liveSnapshot?.windows.count == 2)
        precondition(liveSnapshot?.windows.first?.title == "5 小时")
        precondition(liveSnapshot?.windows.first?.remainingPercent == 68.0)
        precondition(liveSnapshot?.creditsBalance == "4.50")

        let local = """
        {"payload":{"rate_limits":{"plan_type":"pro","primary":{"used_percent":2,"window_minutes":300,"resets_at":1700001000},"secondary":{"used_percent":29,"window_minutes":10080,"resets_at":1700600000}}}}
        """.data(using: .utf8)!
        let localSnapshot = parse(data: local, source: .localLog, capturedAt: capturedAt)
        precondition(localSnapshot?.planType == "pro")
        precondition(localSnapshot?.windows.first?.title == "5 小时")
        precondition(localSnapshot?.windows.last?.title == "7 天")
        precondition(abs((localSnapshot?.windows.last?.remainingPercent ?? 0) - 71) < 0.01)
    }

    private static func collect(
        _ any: Any,
        inheritedPlan: String?,
        inheritedCredits: String?,
        capturedAt: Date,
        source: UsageSource,
        best: inout UsageSnapshot?
    ) {
        if let array = any as? [Any] {
            for item in array {
                collect(
                    item,
                    inheritedPlan: inheritedPlan,
                    inheritedCredits: inheritedCredits,
                    capturedAt: capturedAt,
                    source: source,
                    best: &best
                )
            }
            return
        }
        guard let dict = any as? [String: Any] else { return }

        let plan = string(dict["plan_type"]) ?? inheritedPlan
        let creditsBalance = credits(in: dict) ?? inheritedCredits
        let primary = window(
            dict["primary_window"] ?? dict["primary"],
            id: "primary",
            fallbackTitle: "短时窗口",
            capturedAt: capturedAt
        )
        let secondary = window(
            dict["secondary_window"] ?? dict["secondary"],
            id: "secondary",
            fallbackTitle: "长时窗口",
            capturedAt: capturedAt
        )
        if primary != nil || secondary != nil {
            var windows = [primary, secondary].compactMap { $0 }
            windows.append(contentsOf: extraWindows(in: dict, capturedAt: capturedAt))
            let candidate = UsageSnapshot(
                planType: plan,
                windows: windows,
                creditsBalance: creditsBalance,
                source: source,
                capturedAt: capturedAt
            )
            if best == nil || candidate.windows.count > (best?.windows.count ?? 0) {
                best = candidate
            }
        }

        for value in dict.values {
            collect(
                value,
                inheritedPlan: plan,
                inheritedCredits: creditsBalance,
                capturedAt: capturedAt,
                source: source,
                best: &best
            )
        }
    }

    private static func extraWindows(in dict: [String: Any], capturedAt: Date) -> [UsageWindow] {
        let raw = dict["additional_rate_limits"] ?? dict["additionalRateLimits"]
        guard let items = raw as? [Any] else { return [] }
        return items.enumerated().compactMap { index, item in
            window(item, id: "extra-\(index)", fallbackTitle: "其他额度", capturedAt: capturedAt)
        }
    }

    private static func window(_ any: Any?, id: String, fallbackTitle: String, capturedAt: Date) -> UsageWindow? {
        guard let dict = any as? [String: Any], let used = number(dict["used_percent"] ?? dict["usedPercent"]) else {
            return nil
        }
        let seconds = windowSeconds(in: dict)
        return UsageWindow(
            id: id,
            title: string(dict["name"] ?? dict["label"]) ?? title(for: seconds, id: id, fallback: fallbackTitle),
            usedPercent: min(100, max(0, used)),
            resetAt: resetDate(in: dict, capturedAt: capturedAt),
            windowSeconds: seconds
        )
    }

    private static func windowSeconds(in dict: [String: Any]) -> TimeInterval? {
        if let seconds = number(dict["limit_window_seconds"] ?? dict["window_seconds"]) {
            return seconds
        }
        if let minutes = number(dict["window_minutes"] ?? dict["windowMinutes"]) {
            return minutes * 60
        }
        return nil
    }

    private static func resetDate(in dict: [String: Any], capturedAt: Date) -> Date? {
        if var timestamp = number(dict["reset_at"] ?? dict["resets_at"] ?? dict["resetAt"]) {
            if timestamp > 10_000_000_000 { timestamp /= 1000 }
            return Date(timeIntervalSince1970: timestamp)
        }
        if let after = number(dict["reset_after_seconds"] ?? dict["resetAfterSeconds"]) {
            return capturedAt.addingTimeInterval(after)
        }
        return nil
    }

    private static func title(for seconds: TimeInterval?, id: String, fallback: String) -> String {
        guard let seconds else {
            return id == "primary" ? "短时窗口" : (id == "secondary" ? "长时窗口" : fallback)
        }
        let minutes = Int((seconds / 60).rounded())
        switch minutes {
        case 300: return "5 小时"
        case 10_080: return "7 天"
        case 1_440: return "24 小时"
        default:
            if minutes >= 1_440, minutes % 1_440 == 0 { return "\(minutes / 1_440) 天" }
            if minutes >= 60, minutes % 60 == 0 { return "\(minutes / 60) 小时" }
            return fallback
        }
    }

    private static func credits(in dict: [String: Any]) -> String? {
        guard let credits = dict["credits"] as? [String: Any] else { return nil }
        if credits["unlimited"] as? Bool == true { return L10n.s(.unlimited) }
        if let balance = string(credits["balance"] ?? credits["remaining"]) { return balance }
        return nil
    }

    private static func string(_ any: Any?) -> String? {
        guard let value = any as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func number(_ any: Any?) -> Double? {
        switch any {
        case let value as Double:
            return value
        case let value as Int:
            return Double(value)
        case let value as NSNumber:
            return value.doubleValue
        case let value as String:
            return Double(value)
        default:
            return nil
        }
    }
}
