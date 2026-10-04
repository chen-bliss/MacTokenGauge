import XCTest
@testable import GaugeCore

final class RetryTests: XCTestCase {
    let session = CursorAuthReader.Session(accessToken: "test-token", userID: "user_test", email: nil, membership: nil)
    func defaults() -> UserDefaults {
        let name = "MacTokenGauge.tests.\(UUID())"
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: name) }
        return UserDefaults(suiteName: name)!
    }

    func testExplicitDisabledOnDemandStopsFallbackAndRemembersEndpoint() async throws {
        let calls = RequestRecorder()
        let storage = defaults()
        let payload = Data(#"{"individualUsage":{"plan":{"limit":100,"remaining":50},"onDemand":{"enabled":false}}}"#.utf8)
        XCTAssertEqual(CursorUsageClient.parse(payload)?.windows.map(\.id), ["cursor-total"])
        let parsed = try await CursorUsageClient.fetch(session: session, defaults: storage, sendRequest: { request in
            await calls.record(request.url!.path)
            return (payload, 200)
        })
        XCTAssertTrue(parsed.onDemandDisabled)
        let recorded = await calls.items
        XCTAssertEqual(recorded.count, 1)
        XCTAssertEqual(storage.string(forKey: "cursorPreferredEndpoint"), "/api/dashboard/get-current-period-usage")
        storage.set("/api/usage-summary", forKey: "cursorPreferredEndpoint")
        _ = try await CursorUsageClient.fetch(session: session, defaults: storage, sendRequest: { request in
            await calls.record(request.url!.path)
            return (payload, 200)
        })
        let next = await calls.items
        XCTAssertEqual(next.last, "/api/usage-summary")
    }

    func testCancellationStopsFallbackImmediately() async {
        let calls = RequestRecorder()
        do {
            _ = try await CursorUsageClient.fetch(session: session, defaults: defaults(), sendRequest: { _ in
                await calls.record("request")
                throw CancellationError()
            })
            XCTFail("Expected cancellation")
        } catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
        let recorded = await calls.items
        XCTAssertEqual(recorded.count, 1)
    }

    func test429StopsOtherFallbackEndpoints() async {
        let calls = RequestRecorder()
        do {
            _ = try await CursorUsageClient.fetch(session: session, defaults: defaults(), sendRequest: { _ in
                await calls.record("request")
                throw UsageClientError.rateLimited(Date().addingTimeInterval(120))
            })
            XCTFail("Expected rate limit")
        } catch UsageClientError.rateLimited {} catch { XCTFail("Unexpected error: \(error)") }
        let recorded = await calls.items
        XCTAssertEqual(recorded.count, 1)
    }

    func testRetryAfterSecondsHTTPDateAndExponentialFallback() async throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        XCTAssertEqual(RequestBackoff.retryDate("120", now: now), now.addingTimeInterval(120))
        XCTAssertEqual(RequestBackoff.retryDate("Tue, 14 Nov 2023 22:15:20 GMT", now: now), now.addingTimeInterval(120))
        XCTAssertNil(RequestBackoff.retryDate("invalid", now: now))
        let policy = RequestBackoff()
        let first = await policy.limited("test", header: nil, now: now)
        let second = await policy.limited("test", header: nil, now: now)
        XCTAssertEqual(first, now.addingTimeInterval(60))
        XCTAssertEqual(second, now.addingTimeInterval(120))
        do { try await policy.check("test", now: now); XCTFail("Expected cooldown") }
        catch UsageClientError.rateLimited(let until) { XCTAssertEqual(until, second) }
        await policy.succeeded("test")
        try await policy.check("test", now: now)
    }
}
