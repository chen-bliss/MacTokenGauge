import Foundation

struct CodexSession: Sendable {
    var accessToken: String
    var accountID: String?
    var expiresAt: Date?

    var isExpired: Bool {
        guard let expiresAt else { return false }
        return expiresAt.timeIntervalSinceNow < 60
    }
}

enum CodexAuthReader {
    static func codexHome() -> URL {
        if let override = ProcessInfo.processInfo.environment["CODEX_HOME"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex", isDirectory: true)
    }

    static func load() -> LoadResult {
        let url = codexHome().appendingPathComponent("auth.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return .missing }
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .unreadable
        }

        let tokens = json["tokens"] as? [String: Any] ?? json
        guard let accessToken = tokens["access_token"] as? String, !accessToken.isEmpty else {
            if json["OPENAI_API_KEY"] != nil { return .apiKeyOnly }
            return .missing
        }

        let session = CodexSession(
            accessToken: accessToken,
            accountID: (tokens["account_id"] as? String) ?? accountID(in: accessToken),
            expiresAt: expiry(in: accessToken)
        )
        return session.isExpired ? .expired : .ready(session)
    }

    enum LoadResult {
        case ready(CodexSession)
        case missing
        case expired
        case apiKeyOnly
        case unreadable
    }

    private static func jwtPayload(_ token: String) -> [String: Any]? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var payload = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while payload.count % 4 != 0 { payload.append("=") }
        guard let data = Data(base64Encoded: payload),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return json
    }

    private static func expiry(in token: String) -> Date? {
        guard let exp = jwtPayload(token)?["exp"] as? NSNumber else { return nil }
        return Date(timeIntervalSince1970: exp.doubleValue)
    }

    private static func accountID(in token: String) -> String? {
        guard let auth = jwtPayload(token)?["https://api.openai.com/auth"] as? [String: Any] else { return nil }
        return auth["chatgpt_account_id"] as? String ?? auth["chatgpt_account_user_id"] as? String
    }
}
