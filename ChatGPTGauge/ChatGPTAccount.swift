import Foundation

enum ChatGPTAccountLoader {
    static func load(includeLive: Bool) async -> ProviderAccount {
        async let localTask = Task.detached(priority: .utility) { SessionLogReader.latestSnapshot() }.value
        let auth = CodexAuthReader.load()
        let local = await localTask

        var live: UsageSnapshot?
        var problem: String?

        if includeLive {
            switch auth {
            case .ready(let session):
                do {
                    live = try await UsageClient.fetch(session: session)
                } catch UsageClientError.unauthorized {
                    problem = L10n.s(.gptUnauthorized)
                } catch UsageClientError.transport(let error) {
                    problem = transport(error)
                } catch UsageClientError.http(let code) {
                    problem = L10n.f(.gptHTTP, code)
                } catch {
                    problem = L10n.s(.gptTemporary)
                }
            case .expired:
                problem = L10n.s(.gptExpired)
            case .missing:
                problem = L10n.s(.gptMissing)
            case .apiKeyOnly:
                problem = L10n.s(.gptAPIKey)
            case .unreadable:
                problem = L10n.s(.gptUnreadable)
            }
        }

        if let live {
            return make(from: live, status: L10n.s(.official))
        }
        if let local {
            return make(from: local, status: problem ?? L10n.s(.localCodex))
        }
        return ProviderAccount(
            id: "chatgpt",
            name: "ChatGPT",
            menuTitle: "GPT",
            plan: nil,
            accountLabel: nil,
            windows: [],
            status: problem ?? L10n.s(.noUsageCodex),
            capturedAt: nil,
            creditsBalance: nil,
            note: nil,
            origin: .localLog
        )
    }

    private static func make(from snapshot: UsageSnapshot, status: String) -> ProviderAccount {
        ProviderAccount(
            id: "chatgpt",
            name: "ChatGPT",
            menuTitle: "GPT",
            plan: UsageFormatting.planName(snapshot.planType, fallback: "ChatGPT"),
            accountLabel: nil,
            windows: snapshot.windows,
            status: status,
            capturedAt: snapshot.capturedAt,
            creditsBalance: snapshot.creditsBalance,
            note: snapshot.source == .localLog ? L10n.s(.localNote) : nil,
            origin: snapshot.source
        )
    }

    private static func transport(_ error: URLError) -> String {
        switch error.code {
        case .notConnectedToInternet, .networkConnectionLost:
            return L10n.s(.gptOffline)
        case .timedOut:
            return L10n.s(.gptTimeout)
        default:
            return L10n.s(.gptUnreachable)
        }
    }
}
