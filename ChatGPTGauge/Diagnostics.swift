import AppKit
import Foundation

/// Whitelist fields instead of trying to redact raw provider responses or error text.
enum Diagnostics {
    static func data(accounts: [ProviderAccount], version: String, generatedAt: Date = Date()) throws -> Data {
        struct Report: Encodable {
            struct Service: Encodable {
                var provider: String
                var state: AccountState.RawValue
                var origin: UsageSource.RawValue
                var capturedAt: Date?
                var attemptedAt: Date?
                var retryAfter: Date?
                var quotaWindowCount: Int
                var amountWindowCount: Int
            }
            var appVersion: String
            var generatedAt: Date
            var services: [Service]
        }
        let report = Report(appVersion: version, generatedAt: generatedAt, services: accounts.map {
            .init(provider: $0.id, state: $0.state.rawValue, origin: $0.origin.rawValue,
                  capturedAt: $0.capturedAt, attemptedAt: $0.attemptedAt, retryAfter: $0.retryAfter,
                  quotaWindowCount: $0.windows.filter(\.isQuota).count,
                  amountWindowCount: $0.windows.filter { !$0.isQuota }.count)
        })
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(report)
    }
}

extension UsageMonitor {
    func exportDiagnostics() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "MacTokenGauge-diagnostics.json"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
            try Diagnostics.data(accounts: accounts, version: version).write(to: url, options: .atomic)
        } catch {
            let alert = NSAlert(error: error)
            alert.runModal()
        }
    }
}
