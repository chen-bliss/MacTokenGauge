import XCTest
@testable import GaugeCore

final class DataTests: XCTestCase {
    let moment = Date(timeIntervalSince1970: 1_700_000_000)
    func data(_ text: String) -> Data { Data(text.utf8) }
    func window(_ id: String, remaining: Double, seconds: Double = 300) -> UsageWindow {
        UsageWindow(id: id, title: id, usedPercent: 100 - remaining, resetAt: nil, windowSeconds: seconds)
    }
    func account(_ windows: [UsageWindow], state: AccountState = .current, identity: String? = "A") -> ProviderAccount {
        ProviderAccount(id: "chatgpt", name: "ChatGPT", menuTitle: "GPT", plan: "Plus", accountLabel: nil,
                        windows: windows, status: "official", capturedAt: moment, creditsBalance: nil, note: nil,
                        state: state, attemptedAt: moment, accountIdentity: identity)
    }

    func testOfficialMainAndNestedAdditionalLimitsStaySeparate() throws {
        let response = data("""
        {"plan_type":"plus","rate_limit":{"primary_window":{"used_percent":20,"limit_window_seconds":18000},"secondary_window":{"used_percent":30}},"additional_rate_limits":[{"limit_name":"model","rate_limit":{"primary_window":{"used_percent":90},"secondary_window":{"used_percent":95}}}],"credits":{"balance":"4.50"}}
        """)
        for _ in 0..<100 {
            let snapshot = try XCTUnwrap(UsageParser.parse(data: response, source: .live, capturedAt: moment))
            XCTAssertEqual(snapshot.windows.map(\.id), ["primary", "secondary", "extra-model-0-primary", "extra-model-0-secondary"])
            XCTAssertEqual(snapshot.windows[0].remainingPercent, 80)
            XCTAssertEqual(snapshot.windows[2].remainingPercent, 10)
            XCTAssertEqual(snapshot.creditsBalance, "4.50")
            XCTAssertEqual(UsageFormatting.headline(account(snapshot.windows).headlineWindows)?.id, "secondary")
        }
    }

    func testUnknownStructureIsRejectedRatherThanSearchedRecursively() {
        let response = data(#"{"mystery":{"rate_limit":{"primary_window":{"used_percent":90}}}}"#)
        XCTAssertNil(UsageParser.parse(data: response, source: .live, capturedAt: moment))
        XCTAssertNil(UsageParser.parse(data: data(#"{"additional_rate_limits":[{"primary_window":{"used_percent":90}}]}"#), source: .live, capturedAt: moment))
    }

    func testLocalEventUsesSeparateEntryPointAndEventTimeForRelativeReset() throws {
        let response = data(#"{"payload":{"rate_limits":{"plan_type":"pro","primary":{"used_percent":2,"window_minutes":300,"reset_after_seconds":60},"secondary":{"used_percent":29,"window_minutes":10080}}}}"#)
        let snapshot = try XCTUnwrap(UsageParser.parse(data: response, source: .localLog, capturedAt: moment))
        XCTAssertEqual(snapshot.planType, "pro")
        XCTAssertEqual(snapshot.windows[0].resetAt, moment.addingTimeInterval(60))
        XCTAssertEqual(snapshot.windows[1].remainingPercent, 71)
        XCTAssertNil(UsageParser.parse(data: response, source: .live, capturedAt: moment))
    }

    func testAdditionalIDsSurviveReordering() throws {
        let limits: [String: Any] = ["primary_window": ["used_percent": 10]]
        let a: [String: Any] = ["limit_name": "A", "rate_limit": limits]
        let b: [String: Any] = ["limit_name": "B", "rate_limit": limits]
        func ids(_ extras: [[String: Any]]) throws -> Set<String> {
            let json = try JSONSerialization.data(withJSONObject: ["rate_limit": limits, "additional_rate_limits": extras])
            return Set(try XCTUnwrap(UsageParser.parse(data: json, source: .live, capturedAt: moment)).windows.map(\.id))
        }
        XCTAssertEqual(try ids([a, b]), try ids([b, a]))
    }

    func testHeadlineIsIndependentOfPermutationAndTieBreaksByStableID() {
        let a = window("A", remaining: 10, seconds: 300)
        let b = window("B", remaining: 14, seconds: 200)
        let c = window("C", remaining: 18, seconds: 100)
        for permutation in [[a,b,c], [a,c,b], [b,a,c], [b,c,a], [c,a,b], [c,b,a]] {
            XCTAssertEqual(UsageFormatting.headline(permutation)?.id, "B")
        }
        XCTAssertEqual(UsageFormatting.headline([window("Z", remaining: 10), window("A", remaining: 10)])?.id, "A")
    }

    func testCursorStructuredBudgetWinsAndReportsConflict() throws {
        let response = data(#"{"displayMessage":"You've used 100% of your included usage","planUsage":{"limit":2000,"remaining":1000,"includedSpend":2000,"autoPercentUsed":35},"individualUsage":{"onDemand":{"enabled":false}}}"#)
        let parsed = try XCTUnwrap(CursorUsageClient.parse(response))
        XCTAssertEqual(parsed.windows.first?.remainingPercent, 50)
        XCTAssertTrue(parsed.note?.contains(L10n.s(.cursorConflict)) == true)
        XCTAssertTrue(parsed.onDemandDisabled)
    }

    func testCursorProseFallbackAndCappedOnDemand() throws {
        let response = data(#"{"displayMessage":"Used 100%","spendLimitUsage":{"individualUsed":800,"individualLimit":5000}}"#)
        let parsed = try XCTUnwrap(CursorUsageClient.parse(response))
        XCTAssertEqual(parsed.windows.first?.usedPercent, 100)
        XCTAssertEqual(parsed.windows.last?.usedPercent, 16)
        XCTAssertTrue(parsed.windows.last?.isQuota == true)
    }

    func testUncappedSpendNeverBecomesRemainingPercent() throws {
        let parsed = try XCTUnwrap(CursorUsageClient.parse(data(#"{"individualUsage":{"onDemand":{"enabled":true,"used":2309,"limit":null}}}"#)))
        let amount = try XCTUnwrap(parsed.windows.first)
        XCTAssertEqual(amount.value, .amount(value: Decimal(string: "23.09")!, currency: "USD"))
        XCTAssertFalse(amount.isQuota)
        XCTAssertNil(UsageFormatting.headline(parsed.windows))
        let owner = ProviderAccount(id: "cursor", name: "Cursor", menuTitle: "Cursor", plan: nil, accountLabel: nil,
                                    windows: parsed.windows, status: "", capturedAt: moment, creditsBalance: nil, note: nil)
        let text = MenuText.render(template: "{name} {percent}", accounts: [owner], now: moment)
        XCTAssertTrue(text.contains(amount.detail!))
        XCTAssertFalse(text.contains("100%"))
        let slot = BarSlot(id: UUID(), target: "cursor.cursor-ondemand", colorHex: "5B8DEF")
        let bar = try XCTUnwrap(BarResolver.resolve(slots: [slot], accounts: [owner], battery: nil, now: moment).first)
        XCTAssertNil(bar.fraction)
        XCTAssertEqual(bar.marker, "$")
        XCTAssertEqual(bar.caption, amount.detail)
    }

    func testFailurePreservesLastLiveReadingButPublishesErrorAndAttempt() {
        let old = account([window("primary", remaining: 80)])
        var fresh = account([window("primary", remaining: 10)], state: .local)
        fresh.origin = .localLog
        fresh.status = "login expired"
        fresh.attemptedAt = moment.addingTimeInterval(60)
        let merged = ProviderAccount.merging(fresh, previous: old)
        XCTAssertEqual(merged.windows, old.windows)
        XCTAssertEqual(merged.origin, .live)
        XCTAssertEqual(merged.capturedAt, old.capturedAt)
        XCTAssertEqual(merged.state, .stale)
        XCTAssertEqual(merged.status, "login expired")
        XCTAssertEqual(merged.attemptedAt, fresh.attemptedAt)
        XCTAssertFalse(merged.canAlert)
        XCTAssertTrue(MenuText.render(template: "{name} {percent}", accounts: [merged], now: moment).hasPrefix("~"))
    }

    func testEmptyFailureAndRecovery() {
        let old = account([window("primary", remaining: 80)])
        let fresh = account([], state: .failed)
        let stale = ProviderAccount.merging(fresh, previous: old)
        XCTAssertEqual(stale.state, .stale)
        XCTAssertEqual(ProviderAccount.merging(old, previous: stale).state, .current)
    }

    func testAccountChangeAndLogoutDiscardPreviousValues() {
        let old = account([window("primary", remaining: 80)])
        XCTAssertTrue(ProviderAccount.merging(account([], state: .failed, identity: "B"), previous: old).windows.isEmpty)
        XCTAssertTrue(ProviderAccount.merging(account([], state: .failed, identity: nil), previous: old).windows.isEmpty)
    }

    func testUnknownGraphicsAreDifferentFromExhaustion() throws {
        let slot = BarSlot(id: UUID(), target: "chatgpt.primary", colorHex: "FFFFFF")
        let unknown = BarResolver.resolve(slots: [slot], accounts: [], battery: nil, now: moment)[0]
        let empty = BarResolver.resolve(slots: [slot], accounts: [account([window("primary", remaining: 0)])], battery: nil, now: moment)[0]
        XCTAssertNil(unknown.fraction)
        XCTAssertEqual(empty.fraction, 0)
        let paused = account([window("primary", remaining: 80)], state: .paused)
        XCTAssertNil(BarResolver.resolve(slots: [slot], accounts: [paused], battery: nil, now: moment)[0].fraction)
        XCTAssertFalse(MenuText.render(template: "{percent}", accounts: [paused], now: moment).contains("80%"))
    }

    func testInvalidNumericFieldsAreRejected() {
        XCTAssertNil(JSONValues.number(true))
        XCTAssertNil(JSONValues.number("nan"))
        XCTAssertNil(JSONValues.number("inf"))
        XCTAssertEqual(JSONValues.number(20), 20)
    }

    func testDiagnosticsWhitelistExcludesPrivateFieldsAndValues() throws {
        var owner = account([window("extra-private-account-name", remaining: 12)])
        owner.accountLabel = "private@example.com"
        owner.status = "Bearer secret-token"
        owner.note = "private conversation"
        let text = String(decoding: try Diagnostics.data(accounts: [owner], version: "test"), as: UTF8.self)
        for secret in ["private", "secret-token", "remainingPercent", "accountIdentity", "accountLabel", "windows"] {
            XCTAssertFalse(text.contains(secret))
        }
        XCTAssertTrue(text.contains("quotaWindowCount"))
    }
}
