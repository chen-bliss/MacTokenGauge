import Foundation

enum UsageParser {
    static func parse(data: Data, source: UsageSource, capturedAt: Date) -> UsageSnapshot? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        switch source {
        case .live: return parseOfficial(json, capturedAt: capturedAt)
        case .localLog: return parseLocalEvent(json, capturedAt: capturedAt)
        }
    }

    private static func parseOfficial(_ json: [String: Any], capturedAt: Date) -> UsageSnapshot? {
        guard let limits = json["rate_limit"] as? [String: Any] else { return nil }
        var windows = primaryWindows(limits, prefix: "", capturedAt: capturedAt)
        guard !windows.isEmpty else { return nil }
        let extra = json["additional_rate_limits"] ?? limits["additional_rate_limits"]
        windows += extraWindows(extra, capturedAt: capturedAt)
        return UsageSnapshot(planType: string(json["plan_type"]), windows: windows,
                             creditsBalance: credits(in: json), source: .live, capturedAt: capturedAt)
    }

    private static func parseLocalEvent(_ json: [String: Any], capturedAt: Date) -> UsageSnapshot? {
        guard let payload = json["payload"] as? [String: Any],
              let limits = payload["rate_limits"] as? [String: Any] else { return nil }
        let windows = primaryWindows(limits, prefix: "", capturedAt: capturedAt)
        guard !windows.isEmpty else { return nil }
        return UsageSnapshot(planType: string(limits["plan_type"]), windows: windows,
                             creditsBalance: credits(in: limits), source: .localLog, capturedAt: capturedAt)
    }

    private static func primaryWindows(_ limits: [String: Any], prefix: String, capturedAt: Date) -> [UsageWindow] {
        [window(limits["primary_window"] ?? limits["primary"], id: prefix + "primary", fallbackTitle: "短时窗口", capturedAt: capturedAt),
         window(limits["secondary_window"] ?? limits["secondary"], id: prefix + "secondary", fallbackTitle: "长时窗口", capturedAt: capturedAt)]
            .compactMap { $0 }
    }

    private static func extraWindows(_ raw: Any?, capturedAt: Date) -> [UsageWindow] {
        guard let items = raw as? [[String: Any]] else { return [] }
        var seen: [String: Int] = [:]
        return items.flatMap { item -> [UsageWindow] in
            let label = string(item["limit_name"] ?? item["name"] ?? item["label"]) ?? "other"
            // Stable across response reordering when the endpoint supplies an identifier.
            let base = string(item["id"]) ?? label
            let occurrence = seen[base, default: 0]
            seen[base] = occurrence + 1
            let prefix = "extra-\(base)-\(occurrence)-"
            if let limits = item["rate_limit"] as? [String: Any] {
                var windows = primaryWindows(limits, prefix: prefix, capturedAt: capturedAt)
                for index in windows.indices { windows[index].title = label }
                return windows
            }
            return [window(item, id: prefix + "window", fallbackTitle: label, capturedAt: capturedAt)].compactMap { $0 }
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

    private static func number(_ any: Any?) -> Double? { JSONValues.number(any) }
}
