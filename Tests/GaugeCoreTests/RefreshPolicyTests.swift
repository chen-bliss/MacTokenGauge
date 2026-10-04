import XCTest
@testable import GaugeCore

final class RefreshPolicyTests: XCTestCase {
    func testExhaustionGatesOnlyValidLiveQuotasAndResumesAfterReset() {
        let now = Date()
        let reset = now.addingTimeInterval(3600)
        var account = ProviderAccount(id: "chatgpt", name: "GPT", menuTitle: "GPT", plan: nil, accountLabel: nil,
            windows: [UsageWindow(id: "primary", title: "5h", usedPercent: 100, resetAt: reset, windowSeconds: 18000)],
            status: "", capturedAt: now, creditsBalance: nil, note: nil)
        XCTAssertEqual(RefreshPolicy.resumeAt(account, now: now), reset.addingTimeInterval(20))
        XCTAssertFalse(RefreshPolicy.shouldFetch(account: account, enabled: true, force: false, now: now))
        XCTAssertTrue(RefreshPolicy.shouldFetch(account: account, enabled: true, force: true, now: now))
        account.state = .stale
        XCTAssertNil(RefreshPolicy.resumeAt(account, now: now))
        XCTAssertTrue(RefreshPolicy.shouldFetch(account: account, enabled: true, force: false, now: now))
        account.state = .current
        account.retryAfter = now.addingTimeInterval(120)
        XCTAssertFalse(RefreshPolicy.shouldFetch(account: account, enabled: true, force: true, now: now))
        XCTAssertFalse(RefreshPolicy.shouldFetch(account: account, enabled: false, force: true, now: now))
    }

    func testEarliestEligibleServiceAndPowerSaverInterval() {
        let now = Date()
        let cursor = ProviderAccount(id: "cursor", name: "Cursor", menuTitle: "Cursor", plan: nil, accountLabel: nil,
            windows: [], status: "", capturedAt: nil, creditsBalance: nil, note: nil, state: .failed,
            retryAfter: now.addingTimeInterval(600))
        XCTAssertEqual(RefreshPolicy.nextDelay(accounts: [cursor], enabled: ["cursor"], interval: 60, now: now), 600)
        XCTAssertEqual(RefreshPolicy.nextDelay(accounts: [cursor], enabled: ["cursor", "chatgpt"], interval: 60, now: now), 60)
        XCTAssertEqual(RefreshPolicy.interval(minutes: 1, powerSaver: true), 900)
        XCTAssertEqual(RefreshPolicy.interval(minutes: 30, powerSaver: true), 5400)
    }
}
