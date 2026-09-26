import Foundation

enum SessionLogReader {
    static func latestSnapshot() -> UsageSnapshot? {
        let home = CodexAuthReader.codexHome()
        let folders = ["sessions", "archived_sessions"].map { home.appendingPathComponent($0, isDirectory: true) }
        guard let newest = folders.compactMap(newestJSONL).max(by: { $0.date < $1.date }) else { return nil }
        guard let data = tail(newest.url, maxBytes: 2 * 1024 * 1024) else { return nil }
        let text = String(decoding: data, as: UTF8.self)

        for line in text.split(separator: "\n", omittingEmptySubsequences: true).reversed() {
            guard line.contains("rate_limits") || line.contains("used_percent") else { continue }
            guard let lineData = String(line).data(using: .utf8) else { continue }
            if let snapshot = UsageParser.parse(data: lineData, source: .localLog, capturedAt: newest.date) {
                return snapshot
            }
        }
        return nil
    }

    private static func newestJSONL(in root: URL) -> (url: URL, date: Date)? {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return nil
        }
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return nil }

        var newest: (url: URL, date: Date)?
        while let url = enumerator.nextObject() as? URL {
            guard url.pathExtension == "jsonl" else { continue }
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey])
            guard values?.isRegularFile != false else { continue }
            let date = values?.contentModificationDate ?? .distantPast
            if newest == nil || date > newest!.date {
                newest = (url, date)
            }
        }
        return newest
    }

    private static func tail(_ url: URL, maxBytes: Int) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return nil }
        let start = size > UInt64(maxBytes) ? size - UInt64(maxBytes) : 0
        try? handle.seek(toOffset: start)
        return try? handle.readToEnd()
    }
}
