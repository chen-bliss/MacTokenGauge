import Foundation

enum ChatGPTAccountLoader {
    static func load(includeLive: Bool) async -> ProviderAccount {
        let auth = CodexAuthReader.load()

        var live: UsageSnapshot?
        var problem: String?
        var retryAfter: Date?
        var accountID: String?
        var identity: String?
        switch auth {
        case .ready(let session), .expired(let session):
            accountID = session.accountID
            identity = session.identity
        default: break
        }

        if includeLive {
            switch auth {
            case .ready(let session):
                do {
                    live = try await UsageClient.fetch(session: session)
                } catch UsageClientError.rateLimited(let date) {
                    retryAfter = date
                    problem = L10n.f(.gptHTTP, 429)
                } catch UsageClientError.unrecognized {
                    problem = L10n.s(.formatChanged)
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
            return make(from: live, status: L10n.s(.official), identity: identity)
        }
        let local = await SessionLogReader.latestSnapshot(accountID: accountID)
        if let local {
            var result = make(from: local, status: problem ?? L10n.s(.localCodex), identity: identity)
            result.retryAfter = retryAfter
            return result
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
            origin: .localLog,
            state: .failed,
            attemptedAt: Date(),
            accountIdentity: identity,
            retryAfter: retryAfter
        )
    }

    private static func make(from snapshot: UsageSnapshot, status: String, identity: String?) -> ProviderAccount {
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
            origin: snapshot.source,
            state: snapshot.source == .live ? .current : .local,
            attemptedAt: Date(),
            accountIdentity: identity
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
