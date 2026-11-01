import Foundation

enum UsageClientError: Error {
    case unauthorized
    case unrecognized
    case http(Int)
    case transport(URLError)
    case rateLimited(Date)
}

enum UsageClient {
    /// 只把登录令牌发给 ChatGPT 的用量接口。不刷新、不写回 `auth.json`，避免轮换一次性 refresh token。
    static func fetch(session: CodexSession) async throws -> UsageSnapshot {
        guard let url = URL(string: "https://chatgpt.com/backend-api/wham/usage") else {
            throw UsageClientError.unrecognized
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 20
        request.setValue("Bearer \(session.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("ChatGPTGauge", forHTTPHeaderField: "User-Agent")
        if let accountID = session.accountID, !accountID.isEmpty {
            request.setValue(accountID, forHTTPHeaderField: "ChatGPT-Account-Id")
        }

        let (data, http) = try await UsageHTTP.send(request)
        switch http.statusCode {
        case 200:
            guard var snapshot = UsageParser.parse(data: data, source: .live, capturedAt: Date()) else {
                throw UsageClientError.unrecognized
            }
            if let cards = await resetCards(session: session) {
                snapshot.resetCardCount = cards.count
                snapshot.resetCardExpiresAt = cards.expiresAt
            }
            return snapshot
        case 401, 403:
            throw UsageClientError.unauthorized
        default:
            throw UsageClientError.http(http.statusCode)
        }
    }

    /// A missing credit list keeps the count from the usage summary and simply omits the expiry.
    private static func resetCards(session: CodexSession) async -> (count: Int, expiresAt: Date?)? {
        guard let url = URL(string: "https://chatgpt.com/backend-api/wham/rate-limit-reset-credits") else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 20
        request.setValue("Bearer \(session.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("ChatGPTGauge", forHTTPHeaderField: "User-Agent")
        if let accountID = session.accountID, !accountID.isEmpty {
            request.setValue(accountID, forHTTPHeaderField: "ChatGPT-Account-Id")
        }
        guard let (data, http) = try? await UsageHTTP.send(request), http.statusCode == 200 else { return nil }
        return UsageParser.parseResetCards(data: data)
    }
}
