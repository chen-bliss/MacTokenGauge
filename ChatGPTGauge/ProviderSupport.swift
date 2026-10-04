import Foundation
import CryptoKit

/// Hashes stay in memory and never appear in diagnostics.
enum AccountIdentity {
    static func tokenFingerprint(_ token: String) -> String {
        let parts = token.split(separator: ".")
        if parts.count >= 2 {
            var base64 = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
            while base64.count % 4 != 0 { base64.append("=") }
            if let data = Data(base64Encoded: base64),
               let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let subject = payload["sub"] as? String {
                return fingerprint(subject)
            }
        }
        return fingerprint(token)
    }

    static func fingerprint(_ identifier: String) -> String {
        SHA256.hash(data: Data(identifier.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

actor RequestBackoff {
    static let shared = RequestBackoff()
    private var deadlines: [String: Date] = [:]
    private var failures: [String: Int] = [:]

    func check(_ host: String, now: Date = Date()) throws {
        if let deadline = deadlines[host], deadline > now { throw UsageClientError.rateLimited(deadline) }
    }

    func limited(_ host: String, header: String?, now: Date = Date()) -> Date {
        let count = min((failures[host] ?? 0) + 1, 8)
        failures[host] = count
        let delay = min(3600, 60 * pow(2, Double(count - 1)))
        let deadline = Self.retryDate(header, now: now) ?? now.addingTimeInterval(delay)
        deadlines[host] = deadline
        return deadline
    }

    func succeeded(_ host: String) {
        deadlines.removeValue(forKey: host)
        failures.removeValue(forKey: host)
    }

    static func retryDate(_ header: String?, now: Date) -> Date? {
        guard let header else { return nil }
        if let seconds = Double(header), seconds.isFinite {
            return now.addingTimeInterval(min(86400, max(30, seconds)))
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss z"
        guard let date = formatter.date(from: header) else { return nil }
        return now.addingTimeInterval(min(86400, max(30, date.timeIntervalSince(now))))
    }
}

enum UsageHTTP {
    static func send(_ request: URLRequest, session suppliedSession: URLSession? = nil) async throws -> (Data, HTTPURLResponse) {
        try Task.checkCancellation()
        let host = request.url?.host ?? ""
        try await RequestBackoff.shared.check(host)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = request.timeoutInterval
        configuration.timeoutIntervalForResource = request.timeoutInterval
        let session = suppliedSession ?? URLSession(configuration: configuration)
        defer { if suppliedSession == nil { session.invalidateAndCancel() } }
        let data: Data
        let response: URLResponse
        do { (data, response) = try await session.data(for: request) }
        catch let error as URLError {
            if error.code == .cancelled { throw CancellationError() }
            throw UsageClientError.transport(error)
        }
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse else { throw UsageClientError.unrecognized }
        if http.statusCode == 429 {
            let deadline = await RequestBackoff.shared.limited(host, header: http.value(forHTTPHeaderField: "Retry-After"))
            throw UsageClientError.rateLimited(deadline)
        }
        if http.statusCode == 200 { await RequestBackoff.shared.succeeded(host) }
        return (data, http)
    }
}
