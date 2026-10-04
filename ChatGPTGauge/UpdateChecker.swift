import Foundation

enum UpdateResult: Equatable, Sendable {
    case available(version: String, url: URL)
    case upToDate
    case failed
}

enum UpdateChecker {
    static func check(currentVersion: String) async -> UpdateResult {
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/chen-bliss/MacTokenGauge/releases/latest")!)
        request.timeoutInterval = 15
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("MacTokenGauge", forHTTPHeaderField: "User-Agent")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return .failed }
            return parse(data, currentVersion: currentVersion)
        } catch { return .failed }
    }

    static func parse(_ data: Data, currentVersion: String) -> UpdateResult {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              json["draft"] as? Bool != true, json["prerelease"] as? Bool != true,
              let tag = json["tag_name"] as? String,
              let latest = version(tag), let current = version(currentVersion),
              let text = json["html_url"] as? String, let url = URL(string: text),
              url.scheme == "https", url.host == "github.com",
              url.path.hasPrefix("/chen-bliss/MacTokenGauge/releases/tag/") else { return .failed }
        for (left, right) in zip(latest, current) where left != right {
            return left > right ? .available(version: tag, url: url) : .upToDate
        }
        return .upToDate
    }

    private static func version(_ text: String) -> [Int]? {
        let stripped = text.hasPrefix("v") ? String(text.dropFirst()) : text
        let parts = stripped.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3, parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }) else { return nil }
        let numbers = parts.compactMap { Int($0) }
        return numbers.count == 3 ? numbers : nil
    }
}

extension UsageMonitor {
    func checkForUpdates() {
        guard !checkingUpdates else { return }
        checkingUpdates = true
        Task {
            let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.4.0"
            updateResult = await UpdateChecker.check(currentVersion: version)
            checkingUpdates = false
        }
    }
}
