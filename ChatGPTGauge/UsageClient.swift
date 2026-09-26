import Foundation

enum UsageClientError: Error {
    case unauthorized
    case unrecognized
    case http(Int)
    case transport(URLError)
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
            guard let snapshot = UsageParser.parse(data: data, source: .live, capturedAt: Date()) else {
                throw UsageClientError.unrecognized
            }
            return snapshot
        case 401, 403:
            throw UsageClientError.unauthorized
        default:
            throw UsageClientError.http(http.statusCode)
        }
    }
}
