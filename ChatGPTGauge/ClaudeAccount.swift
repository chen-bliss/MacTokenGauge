import Foundation
import Security

enum ClaudeAccountLoader {
    static func load() async -> ProviderAccount {
        switch ClaudeAuthReader.load() {
        case .ready(let session):
            do {
                let snapshot = try await ClaudeUsageClient.fetch(session: session)
                return ProviderAccount(
                    id: "claude",
                    name: "Claude",
                    menuTitle: "Claude",
                    plan: "Claude",
                    accountLabel: nil,
                    windows: snapshot.windows,
                    status: L10n.s(.official),
                    capturedAt: snapshot.capturedAt,
                    creditsBalance: nil,
                    note: nil
                )
            } catch UsageClientError.unauthorized {
                return empty(L10n.s(.claudeUnauthorized))
            } catch UsageClientError.transport(let error) {
                return empty(transport(error))
            } catch UsageClientError.http(let code) where code == 429 {
                return empty(L10n.s(.claude429))
            } catch UsageClientError.http(let code) {
                return empty(L10n.f(.claudeHTTP, code))
            } catch {
                return empty(L10n.s(.claudeTemporary))
            }
        case .expired:
            return empty(L10n.s(.claudeExpired))
        case .apiKeyOnly:
            return empty(L10n.s(.claudeAPIKey))
        case .missing:
            return empty(L10n.s(.claudeMissing))
        case .unreadable:
            return empty(L10n.s(.claudeUnreadable))
        }
    }

    private static func empty(_ status: String) -> ProviderAccount {
        ProviderAccount(
            id: "claude",
            name: "Claude",
            menuTitle: "Claude",
            plan: nil,
            accountLabel: nil,
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
            return L10n.s(.claudeOffline)
        case .timedOut:
            return L10n.s(.claudeTimeout)
        default:
            return L10n.s(.claudeUnreachable)
        }
    }
}

enum ClaudeAuthReader {
    struct Session: Sendable {
        var accessToken: String
    }

    enum LoadResult {
        case ready(Session)
        case expired
        case apiKeyOnly
        case missing
        case unreadable
    }

    static func load() -> LoadResult {
        if let data = credentialsData() {
            return parse(data)
        }
        if hasAPIKey {
            return .apiKeyOnly
        }
        return .missing
    }

    private static var hasAPIKey: Bool {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/settings.json")
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let env = json["env"] as? [String: Any],
              let key = env["ANTHROPIC_API_KEY"] as? String else { return false }
        return !key.isEmpty
    }

    private static func credentialsData() -> Data? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let files = [
            home.appendingPathComponent(".claude/.credentials.json"),
            home.appendingPathComponent(".config/claude/credentials.json")
        ]
        for url in files {
            if let data = try? Data(contentsOf: url), !data.isEmpty { return data }
        }
        for service in ["Claude Code-credentials", "Claude Code", "claude-code"] {
            if let data = keychain(service: service) { return data }
        }
        return nil
    }

    private static func keychain(service: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess else { return nil }
        return item as? Data
    }

    private static func parse(_ data: Data) -> LoadResult {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return .unreadable }
        let oauth = (json["claudeAiOauth"] as? [String: Any]) ?? (json["claudeAiOAuth"] as? [String: Any]) ?? json
        guard let token = oauth["accessToken"] as? String ?? oauth["access_token"] as? String, !token.isEmpty else {
            return hasAPIKey ? .apiKeyOnly : .missing
        }
        if let expires = JSONValues.number(oauth["expiresAt"] ?? oauth["expires_at"]) {
            let date = expires > 10_000_000_000
                ? Date(timeIntervalSince1970: expires / 1000)
                : Date(timeIntervalSince1970: expires)
            if date.timeIntervalSinceNow < 60 { return .expired }
        }
        return .ready(Session(accessToken: token))
    }
}

enum ClaudeUsageClient {
    static func fetch(session: ClaudeAuthReader.Session) async throws -> UsageSnapshot {
        guard let url = URL(string: "https://api.anthropic.com/api/oauth/usage") else {
            throw UsageClientError.unrecognized
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.setValue("Bearer \(session.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        // 不带这个标识时，用量接口会直接返回 429。
        request.setValue("claude-code/2.1.72", forHTTPHeaderField: "User-Agent")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch let error as URLError {
            throw UsageClientError.transport(error)
        }
        guard let http = response as? HTTPURLResponse else { throw UsageClientError.unrecognized }
        switch http.statusCode {
        case 200:
            guard let snapshot = parse(data) else { throw UsageClientError.unrecognized }
            return snapshot
        case 401, 403:
            throw UsageClientError.unauthorized
        default:
            throw UsageClientError.http(http.statusCode)
        }
    }

    static func parse(_ data: Data) -> UsageSnapshot? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let titles = [
            "five_hour": "5 小时",
            "seven_day": "7 天",
            "seven_day_opus": "Opus 每周",
            "seven_day_sonnet": "Sonnet 每周",
            "seven_day_haiku": "Haiku 每周",
            "extra_usage": "额外用量"
        ]
        var windows: [UsageWindow] = []
        for (key, title) in titles {
            guard let bucket = json[key] as? [String: Any],
                  let used = JSONValues.number(bucket["utilization"] ?? bucket["used_percentage"]) else { continue }
            windows.append(UsageWindow(
                id: key,
                title: title,
                usedPercent: min(100, max(0, used)),
                resetAt: JSONValues.date(bucket["resets_at"]),
                windowSeconds: key == "five_hour" ? 18_000 : (key == "seven_day" ? 604_800 : nil)
            ))
        }
        guard !windows.isEmpty else { return nil }
        let order = ["five_hour", "seven_day", "seven_day_opus", "seven_day_sonnet", "seven_day_haiku", "extra_usage"]
        windows.sort { lhs, rhs in
            (order.firstIndex(of: lhs.id) ?? 99) < (order.firstIndex(of: rhs.id) ?? 99)
        }
        return UsageSnapshot(planType: "claude", windows: windows, creditsBalance: nil, source: .live, capturedAt: Date())
    }
}
