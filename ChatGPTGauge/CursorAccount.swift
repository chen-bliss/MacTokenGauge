import Foundation

enum CursorAccountLoader {
    static func load() async -> ProviderAccount {
        guard let session = CursorAuthReader.load() else {
            return account(status: L10n.s(.cursorNoLogin))
        }

        do {
            let parsed = try await CursorUsageClient.fetch(session: session)
            return ProviderAccount(
                id: "cursor",
                name: "Cursor",
                menuTitle: "Cursor",
                plan: UsageFormatting.planName(session.membership, fallback: "Cursor"),
                accountLabel: session.email,
                windows: parsed.windows,
                status: parsed.windows.isEmpty ? L10n.s(.cursorEmpty) : L10n.s(.official),
                capturedAt: Date(),
                creditsBalance: nil,
                note: parsed.note
            )
        } catch UsageClientError.unauthorized {
            return account(status: L10n.s(.cursorUnauthorized), email: session.email)
        } catch UsageClientError.transport(let error) {
            return account(status: transport(error), email: session.email)
        } catch UsageClientError.http(let code) {
            return account(status: L10n.f(.cursorHTTP, code), email: session.email)
        } catch {
            return account(status: L10n.s(.cursorTemporary), email: session.email)
        }
    }

    private static func account(status: String, email: String? = nil) -> ProviderAccount {
        ProviderAccount(
            id: "cursor",
            name: "Cursor",
            menuTitle: "Cursor",
            plan: nil,
            accountLabel: email,
            windows: [],
            status: status,
            capturedAt: nil,
            creditsBalance: nil,
            note: nil
        )
    }

    private static func transport(_ error: URLError) -> String {
        switch error.code {
        case .notConnectedToInternet, .networkConnectionLost:
            return L10n.s(.cursorOffline)
        case .timedOut:
            return L10n.s(.cursorTimeout)
        default:
            return L10n.s(.cursorUnreachable)
        }
    }
}

enum CursorAuthReader {
    struct Session: Sendable {
        var accessToken: String
        var userID: String?
        var email: String?
        var membership: String?
    }

    static func load() -> Session? {
        let database = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Cursor/User/globalStorage/state.vscdb")
        guard FileManager.default.fileExists(atPath: database.path) else { return nil }
        let sql = """
        SELECT replace(replace(key, char(10), ''), char(13), '') || '|~|' || replace(replace(IFNULL(value, ''), char(10), ''), char(13), '')
        FROM ItemTable
        WHERE key IN (
          'cursorAuth/accessToken',
          'cursorAuth/cachedEmail',
          'cursorAuth/stripeMembershipType',
          'cursorAuth/stripeMembershipAuthId'
        );
        """
        guard let rows = sqlite(database.path, sql: sql) else { return nil }
        var values: [String: String] = [:]
        for row in rows.split(separator: "\n") {
            let parts = row.split(separator: "|~|", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { continue }
            values[String(parts[0])] = String(parts[1])
        }
        guard let accessToken = values["cursorAuth/accessToken"], !accessToken.isEmpty else { return nil }
        let authID = values["cursorAuth/stripeMembershipAuthId"]
        return Session(
            accessToken: accessToken,
            userID: userID(from: authID) ?? userID(inToken: accessToken),
            email: values["cursorAuth/cachedEmail"],
            membership: values["cursorAuth/stripeMembershipType"]
        )
    }

    private static func userID(from raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        if let match = raw.split(separator: "|").first(where: { $0.hasPrefix("user_") }) {
            return String(match)
        }
        if raw.hasPrefix("user_") { return raw }
        return nil
    }

    private static func userID(inToken token: String) -> String? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var payload = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while payload.count % 4 != 0 { payload.append("=") }
        guard let data = Data(base64Encoded: payload),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return userID(from: json["sub"] as? String) ?? userID(from: json["user_id"] as? String)
    }

    private static func sqlite(_ path: String, sql: String) -> String? {
        var components = URLComponents()
        components.scheme = "file"
        components.path = path
        guard let base = components.string else { return nil }
        let uri = base + "?mode=ro"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = [uri, sql]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }
        guard process.terminationStatus == 0 else { return nil }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        return String(decoding: data, as: UTF8.self)
    }
}

enum CursorUsageClient {
    struct Parsed: Sendable {
        var windows: [UsageWindow]
        var note: String?
    }

    static func fetch(session: CursorAuthReader.Session) async throws -> Parsed {
        var merged: [UsageWindow] = []
        var note: String?
        var last: Error = UsageClientError.unrecognized
        for request in requests(for: session) {
            do {
                let (data, code) = try await send(request)
                switch code {
                case 200:
                    guard let parsed = parse(data), !parsed.windows.isEmpty else {
                        last = UsageClientError.unrecognized
                        continue
                    }
                    merged = mergeWindows(merged, parsed.windows)
                    if note == nil { note = parsed.note }
                    let hasPlan = merged.contains { $0.id == "cursor-total" || $0.id == "cursor-auto" }
                    let hasOnDemand = merged.contains { $0.id == "cursor-ondemand" }
                    if hasPlan && hasOnDemand { break }
                case 401, 403:
                    last = UsageClientError.unauthorized
                default:
                    last = UsageClientError.http(code)
                }
            } catch {
                last = error
            }
        }
        guard !merged.isEmpty else { throw last }
        return Parsed(windows: ordered(merged), note: note)
    }

    private static func mergeWindows(_ current: [UsageWindow], _ incoming: [UsageWindow]) -> [UsageWindow] {
        var merged = current
        for window in incoming where !merged.contains(where: { $0.id == window.id }) {
            merged.append(window)
        }
        return merged
    }

    private static func ordered(_ windows: [UsageWindow]) -> [UsageWindow] {
        let order = ["cursor-total", "cursor-auto", "cursor-api", "cursor-ondemand", "cursor-requests"]
        return windows.sorted {
            (order.firstIndex(of: $0.id) ?? 99) < (order.firstIndex(of: $1.id) ?? 99)
        }
    }

    private static func requests(for session: CursorAuthReader.Session) -> [URLRequest] {
        var items: [URLRequest] = []
        if let cookie = sessionCookie(session) {
            items.append(webRequest(
                url: "https://cursor.com/api/dashboard/get-current-period-usage",
                method: "POST",
                cookie: cookie,
                token: session.accessToken,
                body: Data("{}".utf8)
            ))
            items.append(webRequest(
                url: "https://cursor.com/api/usage-summary",
                method: "GET",
                cookie: cookie,
                token: session.accessToken,
                body: nil
            ))
        }
        if let url = URL(string: "https://api2.cursor.sh/aiserver.v1.DashboardService/GetCurrentPeriodUsage") {
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.timeoutInterval = 20
            request.httpBody = Data("{}".utf8)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue("Bearer \(session.accessToken)", forHTTPHeaderField: "Authorization")
            request.setValue("1", forHTTPHeaderField: "Connect-Protocol-Version")
            items.append(request)
        }
        if let userID = session.userID,
           var components = URLComponents(string: "https://cursor.com/api/usage") {
            components.queryItems = [URLQueryItem(name: "user", value: userID)]
            if let url = components.url, let cookie = sessionCookie(session) {
                items.append(webRequest(url: url.absoluteString, method: "GET", cookie: cookie, token: session.accessToken, body: nil))
            }
        }
        return items
    }

    private static func webRequest(url: String, method: String, cookie: String, token: String, body: Data?) -> URLRequest {
        var request = URLRequest(url: URL(string: url)!)
        request.httpMethod = method
        request.timeoutInterval = 20
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if body != nil {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("https://cursor.com", forHTTPHeaderField: "Origin")
        request.setValue("https://cursor.com/dashboard", forHTTPHeaderField: "Referer")
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15",
            forHTTPHeaderField: "User-Agent"
        )
        return request
    }

    private static func sessionCookie(_ session: CursorAuthReader.Session) -> String? {
        guard let userID = session.userID, !userID.isEmpty else { return nil }
        return "WorkosCursorSessionToken=\(userID)%3A%3A\(session.accessToken)"
    }

    private static func send(_ request: URLRequest) async throws -> (Data, Int) {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch let error as URLError {
            throw UsageClientError.transport(error)
        }
        guard let http = response as? HTTPURLResponse else { throw UsageClientError.unrecognized }
        return (data, http.statusCode)
    }

    static func selfCheck() {
        let included = Data("""
        {"displayMessage":"You've used 100% of your included usage","planUsage":{"includedSpend":2000,"remaining":0,"limit":2000,"autoPercentUsed":35,"apiPercentUsed":100},"spendLimitUsage":{"individualUsed":800,"individualLimit":5000}}
        """.utf8)
        let parsed = parse(included)
        precondition(parsed?.windows.first { $0.id == "cursor-total" }?.usedPercent == 100)
        precondition(parsed?.windows.first { $0.id == "cursor-auto" }?.usedPercent == 35)
        let capped = parsed?.windows.first { $0.id == "cursor-ondemand" }
        precondition(capped?.detail == nil)
        precondition(abs((capped?.usedPercent ?? -1) - 16) < 0.01)

        let open = Data("""
        {"individualUsage":{"plan":{"used":10,"limit":100,"remaining":90,"autoPercentUsed":4},"onDemand":{"enabled":true,"used":2309,"limit":null}}}
        """.utf8)
        let extra = parse(open)?.windows.first { $0.id == "cursor-ondemand" }
        precondition(extra?.detail == "$23.09")
    }

    static func parse(_ data: Data) -> Parsed? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let plan = planDictionary(in: json)
        let resetAt = JSONValues.date(json["billingCycleEnd"] ?? plan?["billingCycleEnd"] ?? json["endOfMonth"])
        let start = JSONValues.date(json["billingCycleStart"] ?? plan?["billingCycleStart"] ?? json["startOfMonth"])
        let windowSeconds = start.flatMap { opened in resetAt.map { $0.timeIntervalSince(opened) } }
        var windows: [UsageWindow] = []

        if let plan {
            if let message = json["displayMessage"] as? String, let used = percent(in: message) {
                windows.append(window(id: "cursor-total", title: "本月", used: used, resetAt: resetAt, windowSeconds: windowSeconds))
            } else if let used = includedUsedPercent(plan) {
                windows.append(window(id: "cursor-total", title: "本月", used: used, resetAt: resetAt, windowSeconds: windowSeconds))
            } else if let total = JSONValues.number(plan["totalPercentUsed"]) {
                windows.append(window(id: "cursor-total", title: "本月", used: total, resetAt: resetAt, windowSeconds: windowSeconds))
            }
            if let auto = JSONValues.number(plan["autoPercentUsed"]) {
                windows.append(window(id: "cursor-auto", title: "Auto", used: auto, resetAt: resetAt, windowSeconds: windowSeconds))
            }
            if let api = JSONValues.number(plan["apiPercentUsed"]) {
                windows.append(window(id: "cursor-api", title: "API", used: api, resetAt: resetAt, windowSeconds: windowSeconds))
            }
        }

        if !windows.contains(where: { $0.id == "cursor-total" }),
           let message = json["displayMessage"] as? String,
           let used = percent(in: message) {
            windows.insert(window(id: "cursor-total", title: "本月", used: used, resetAt: resetAt, windowSeconds: windowSeconds), at: 0)
        }
        if !windows.contains(where: { $0.id == "cursor-auto" }),
           let message = json["autoModelSelectedDisplayMessage"] as? String,
           let used = percent(in: message) {
            windows.append(window(id: "cursor-auto", title: "Auto", used: used, resetAt: resetAt, windowSeconds: windowSeconds))
        }
        if !windows.contains(where: { $0.id == "cursor-api" }),
           let message = json["namedModelSelectedDisplayMessage"] as? String,
           let used = percent(in: message) {
            windows.append(window(id: "cursor-api", title: "API", used: used, resetAt: resetAt, windowSeconds: windowSeconds))
        }

        appendOnDemand(json, to: &windows, resetAt: resetAt, windowSeconds: windowSeconds)

        let legacyModel = (json["gpt-4"] as? [String: Any]) ?? (plan?["gpt-4"] as? [String: Any])
        if !windows.contains(where: { $0.id == "cursor-total" || $0.id == "cursor-requests" }),
           let model = legacyModel,
           let used = JSONValues.number(model["numRequests"]),
           let max = JSONValues.number(model["maxRequestUsage"]),
           max > 0 {
            let monthStart = JSONValues.date(json["startOfMonth"])
            let end = monthStart.flatMap { Calendar(identifier: .gregorian).date(byAdding: .month, value: 1, to: $0) } ?? resetAt
            windows.append(window(id: "cursor-requests", title: "本月请求", used: used / max * 100, resetAt: end, windowSeconds: windowSeconds))
        }

        guard !windows.isEmpty else { return nil }
        return Parsed(windows: windows, note: plan.flatMap(dollarNote))
    }

    private static func planDictionary(in json: [String: Any]) -> [String: Any]? {
        if let plan = json["planUsage"] as? [String: Any] { return plan }
        if let individual = json["individualUsage"] as? [String: Any],
           let plan = individual["plan"] as? [String: Any] {
            return plan
        }
        return nil
    }

    private static func onDemandDictionary(in json: [String: Any]) -> [String: Any]? {
        if let individual = json["individualUsage"] as? [String: Any],
           let onDemand = individual["onDemand"] as? [String: Any] {
            return onDemand
        }
        if let team = json["teamUsage"] as? [String: Any],
           let onDemand = team["onDemand"] as? [String: Any] {
            return onDemand
        }
        return nil
    }

    /// The sentence on Cursor's dashboard is included spend against the limit.
    /// `totalPercentUsed` is a different meter and can stay low after that budget is gone.
    /// `remaining` wins when it is present, so a leftover included budget is not shown as empty.
    private static func includedUsedPercent(_ plan: [String: Any]) -> Double? {
        guard let limit = JSONValues.number(plan["limit"]), limit > 0 else { return nil }
        if let remaining = JSONValues.number(plan["remaining"]) {
            return min(100, max(0, (limit - remaining) / limit * 100))
        }
        if let included = JSONValues.number(plan["includedSpend"]) ?? JSONValues.number(plan["used"]) {
            return min(100, max(0, included / limit * 100))
        }
        return nil
    }

    private static func appendOnDemand(_ json: [String: Any], to windows: inout [UsageWindow], resetAt: Date?, windowSeconds: TimeInterval?) {
        guard !windows.contains(where: { $0.id == "cursor-ondemand" }) else { return }
        if let spend = spendLimitDictionary(in: json) {
            let used = JSONValues.number(spend["individualUsed"] ?? spend["pooledUsed"] ?? spend["used"])
            let limit = JSONValues.number(spend["individualLimit"] ?? spend["pooledLimit"] ?? spend["limit"])
            if let window = onDemandWindow(used: used, limit: limit, resetAt: resetAt, windowSeconds: windowSeconds) {
                windows.append(window)
                return
            }
        }
        guard let onDemand = onDemandDictionary(in: json) else { return }
        if let enabled = onDemand["enabled"] as? Bool, !enabled { return }
        let used = JSONValues.number(onDemand["used"])
        let limit = JSONValues.number(onDemand["limit"])
        if let window = onDemandWindow(used: used, limit: limit, resetAt: resetAt, windowSeconds: windowSeconds) {
            windows.append(window)
        }
    }

    private static func onDemandWindow(used: Double?, limit: Double?, resetAt: Date?, windowSeconds: TimeInterval?) -> UsageWindow? {
        guard let used, used > 0 || (limit ?? 0) > 0 else { return nil }
        if let limit, limit > 0 {
            return window(id: "cursor-ondemand", title: "按量", used: used / limit * 100, resetAt: resetAt, windowSeconds: windowSeconds)
        }
        var open = window(id: "cursor-ondemand", title: "按量", used: 0, resetAt: resetAt, windowSeconds: windowSeconds)
        open.detail = "$\(money(used))"
        return open
    }

    private static func spendLimitDictionary(in json: [String: Any]) -> [String: Any]? {
        json["spendLimitUsage"] as? [String: Any]
    }

    private static func percent(in text: String) -> Double? {
        guard let range = text.range(of: #"(\d+(?:\.\d+)?)\s*%"#, options: .regularExpression) else { return nil }
        let number = text[range].filter { $0.isNumber || $0 == "." }
        return Double(number)
    }

    private static func window(id: String, title: String, used: Double, resetAt: Date?, windowSeconds: TimeInterval?) -> UsageWindow {
        UsageWindow(id: id, title: title, usedPercent: min(100, max(0, used)), resetAt: resetAt, windowSeconds: windowSeconds)
    }

    private static func dollarNote(_ plan: [String: Any]) -> String? {
        guard let limit = JSONValues.number(plan["limit"]), limit > 0 else { return nil }
        let used = JSONValues.number(plan["includedSpend"]) ?? JSONValues.number(plan["used"])
        guard let used else { return nil }
        return L10n.f(.dollarNote, money(used), money(limit))
    }

    private static func money(_ cents: Double) -> String {
        String(format: "%.2f", cents / 100)
    }
}

enum JSONValues {
    static func number(_ any: Any?) -> Double? {
        switch any {
        case let value as Double: return value
        case let value as Int: return Double(value)
        case let value as NSNumber: return value.doubleValue
        case let value as String: return Double(value)
        default: return nil
        }
    }

    static func date(_ any: Any?) -> Date? {
        if let number = number(any) {
            let seconds = number > 10_000_000_000 ? number / 1000 : number
            return Date(timeIntervalSince1970: seconds)
        }
        guard let text = any as? String, !text.isEmpty else { return nil }
        if let number = Double(text) { return date(number) }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: text) ?? ISO8601DateFormatter().date(from: text)
    }
}
