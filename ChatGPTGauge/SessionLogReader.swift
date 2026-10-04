import Foundation

/// Logs without an explicit account ID cannot safely be used as account usage.
/// The directory index is cached; at most 20 recent files and 2 MiB per file are read.
enum SessionLogReader {
    private static let store = SessionLogStore(home: CodexAuthReader.codexHome())

    static func latestSnapshot(accountID: String?) async -> UsageSnapshot? {
        guard let accountID, !accountID.isEmpty else { return nil }
        return await store.latestSnapshot(accountID: accountID, now: Date())
    }
}

actor SessionLogStore {
    private let home: URL
    private var indexedAt = Date.distantPast
    private var candidates: [URL] = []
    private struct FileCache {
        var modified: Date
        var size: UInt64
        var accountID: String?
        var snapshot: UsageSnapshot?
        var pendingLine: Data
    }
    private var cache: [URL: FileCache] = [:]
    static let maximumAge: TimeInterval = 24 * 60 * 60

    init(home: URL) { self.home = home }

    func latestSnapshot(accountID: String, now: Date) -> UsageSnapshot? {
        if now.timeIntervalSince(indexedAt) >= 60 {
            candidates = recentFiles()
            indexedAt = now
            cache = cache.filter { candidates.contains($0.key) }
        }
        var found: [UsageSnapshot] = []
        for var url in candidates {
            url.removeAllCachedResourceValues()
            guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]),
                  let modified = values.contentModificationDate, let byteCount = values.fileSize else { continue }
            let size = UInt64(byteCount)
            if cache[url]?.modified != modified || cache[url]?.size != size {
                read(url, modified: modified, size: size)
            }
            guard let entry = cache[url], entry.accountID == accountID,
                  let snapshot = entry.snapshot,
                  now.timeIntervalSince(snapshot.capturedAt) <= Self.maximumAge,
                  snapshot.capturedAt.timeIntervalSince(now) <= 300 else { continue }
            found.append(snapshot)
        }
        return found.max { $0.capturedAt < $1.capturedAt }
    }

    private func recentFiles() -> [URL] {
        var files: [(URL, Date)] = []
        for folder in ["sessions", "archived_sessions"] {
            let root = home.appendingPathComponent(folder)
            guard let iterator = FileManager.default.enumerator(at: root,
                includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
            while let url = iterator.nextObject() as? URL {
                guard url.pathExtension == "jsonl",
                      let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey]),
                      values.isRegularFile == true else { continue }
                files.append((url, values.contentModificationDate ?? .distantPast))
                // Retain only the bounded index, even in a large archive.
                files.sort { $0.1 == $1.1 ? $0.0.path < $1.0.path : $0.1 > $1.1 }
                if files.count > 20 { files.removeLast() }
            }
        }
        return files.map(\.0)
    }

    private func read(_ url: URL, modified: Date, size: UInt64) {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? handle.close() }
        let old = cache[url]
        let appending = old.map { size > $0.size } ?? false
        var identity = appending ? old?.accountID : nil
        var snapshot = appending ? old?.snapshot : nil
        if identity == nil, let head = try? handle.read(upToCount: 64 * 1024) {
            for line in String(decoding: head, as: UTF8.self).split(separator: "\n") {
                guard let json = object(String(line)), json["type"] as? String == "session_meta",
                      let payload = json["payload"] as? [String: Any] else { continue }
                identity = payload["account_id"] as? String
            }
        }
        let tailStart = size > 2 * 1024 * 1024 ? size - 2 * 1024 * 1024 : 0
        let start = appending ? max(old?.size ?? 0, tailStart) : tailStart
        try? handle.seek(toOffset: start)
        guard let bytes = try? handle.readToEnd() else { return }
        var data = (appending && start == old?.size) ? (old?.pendingLine ?? Data()) : Data()
        data.append(bytes)
        var lines = data.split(separator: 10, omittingEmptySubsequences: false)
        // Keep an incomplete appended JSONL event for the next read.
        let pending = data.last == 10 ? Data() : Data(lines.popLast() ?? Data.SubSequence())
        if start > 0 && !appending && !lines.isEmpty { lines.removeFirst() }
        for line in lines {
            guard let json = object(String(decoding: line, as: UTF8.self)) else { continue }
            let payload = json["payload"] as? [String: Any]
            if let eventIdentity = payload?["account_id"] as? String {
                if identity != nil && identity != eventIdentity { snapshot = nil }
                identity = eventIdentity
            }
            guard let timestamp = JSONValues.date(json["timestamp"]),
                  let event = try? JSONSerialization.data(withJSONObject: json),
                  let parsed = UsageParser.parse(data: event, source: .localLog, capturedAt: timestamp) else { continue }
            if snapshot == nil || timestamp > snapshot!.capturedAt { snapshot = parsed }
        }
        cache[url] = FileCache(modified: modified, size: size, accountID: identity, snapshot: snapshot, pendingLine: pending)
    }

    private func object(_ line: String) -> [String: Any]? {
        try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
    }
}
