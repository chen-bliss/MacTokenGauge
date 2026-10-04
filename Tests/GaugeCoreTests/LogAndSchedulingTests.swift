import XCTest
@testable import GaugeCore

final class LogAndSchedulingTests: XCTestCase {
    func defaults() -> UserDefaults {
        let name = "MacTokenGauge.tests.\(UUID())"
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: name) }
        defaults.set(true, forKey: "onboardingComplete")
        defaults.set(false, forKey: "alertsEnabled")
        return defaults
    }
    func account(_ id: String, remaining: Double = 70) -> ProviderAccount {
        ProviderAccount(id: id, name: id, menuTitle: id, plan: nil, accountLabel: nil,
                        windows: [UsageWindow(id: "primary", title: "5h", usedPercent: 100 - remaining, resetAt: nil, windowSeconds: 18000)],
                        status: "official", capturedAt: Date(), creditsBalance: nil, note: nil, attemptedAt: Date())
    }
    func log(_ account: String?, time: Date, remaining: Double = 80) -> String {
        let identity = account.map { ",\"account_id\":\"\($0)\"" } ?? ""
        return "{\"timestamp\":\"\(ISO8601DateFormatter().string(from: time))\",\"type\":\"event_msg\",\"payload\":{\"rate_limits\":{\"primary\":{\"used_percent\":\(100 - remaining),\"reset_after_seconds\":60}}\(identity)}}\n"
    }
    func temporaryHome() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("sessions"), withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    func testSearchContinuesPastNewestFileWithoutQuotaAndUsesEventTimestamp() async throws {
        let root = try temporaryHome()
        let now = Date()
        let eventTime = now.addingTimeInterval(-600)
        try Data(log("A", time: eventTime).utf8).write(to: root.appendingPathComponent("sessions/old.jsonl"))
        let newest = root.appendingPathComponent("sessions/new.jsonl")
        try Data("{\"type\":\"message\"}\n".utf8).write(to: newest)
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(1)], ofItemAtPath: newest.path)
        let snapshot = await SessionLogStore(home: root).latestSnapshot(accountID: "A", now: now)
        let captured = try XCTUnwrap(snapshot?.capturedAt)
        XCTAssertEqual(captured.timeIntervalSince1970, eventTime.timeIntervalSince1970, accuracy: 1)
        XCTAssertEqual(snapshot?.windows.first?.resetAt, captured.addingTimeInterval(60))
    }

    func testLogAccountValidationAndMaximumAge() async throws {
        let root = try temporaryHome()
        let now = Date()
        let url = root.appendingPathComponent("sessions/test.jsonl")
        try Data(log("B", time: now).utf8).write(to: url)
        let reader = SessionLogStore(home: root)
        let wrong = await reader.latestSnapshot(accountID: "A", now: now)
        XCTAssertNil(wrong)
        try Data(log(nil, time: now).utf8).write(to: url)
        let unknown = await reader.latestSnapshot(accountID: "A", now: now)
        XCTAssertNil(unknown)
        try Data(log("A", time: now.addingTimeInterval(-90000)).utf8).write(to: url)
        let expired = await reader.latestSnapshot(accountID: "A", now: now)
        XCTAssertNil(expired)
        try Data(log("A", time: now.addingTimeInterval(600)).utf8).write(to: url)
        let future = await reader.latestSnapshot(accountID: "A", now: now)
        XCTAssertNil(future)
    }

    func testAppendedPartialEventAndAccountSwitch() async throws {
        let root = try temporaryHome()
        let now = Date()
        let url = root.appendingPathComponent("sessions/test.jsonl")
        try Data(log("A", time: now.addingTimeInterval(-10)).utf8).write(to: url)
        let reader = SessionLogStore(home: root)
        let initial = await reader.latestSnapshot(accountID: "A", now: now)
        XCTAssertEqual(initial?.windows.first?.remainingPercent, 80)
        let extra = Data(log("A", time: now, remaining: 50).utf8)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: extra.prefix(20))
        let partial = await reader.latestSnapshot(accountID: "A", now: now)
        XCTAssertEqual(partial?.windows.first?.remainingPercent, 80)
        try handle.write(contentsOf: extra.dropFirst(20))
        let completed = await reader.latestSnapshot(accountID: "A", now: now)
        XCTAssertEqual(completed?.windows.first?.remainingPercent, 50)
        let switched = await reader.latestSnapshot(accountID: "B", now: now)
        XCTAssertNil(switched)
    }

    @MainActor func testBatteryDependencyIncludesGraphicSlotsOnlyWhenTheyAreVisible() async {
        let slot = BarSlot(id: UUID(), target: "battery", colorHex: "FFFFFF")
        for style in [MenuBarStyle.bars, .rings, .combined] {
            XCTAssertTrue(UsageMonitor.batteryNeeded(showBattery: false, style: style, slots: [slot]))
        }
        XCTAssertFalse(UsageMonitor.batteryNeeded(showBattery: false, style: .text, slots: [slot]))
        XCTAssertTrue(UsageMonitor.batteryNeeded(showBattery: true, style: .text, slots: []))
        XCTAssertTrue(UsageMonitor.batteryNeeded(showBattery: false, style: .battery, slots: []))
    }

    @MainActor func testAppearanceThresholdAndIntervalChangesNeverFetch() async {
        let calls = RequestRecorder()
        let monitor = UsageMonitor(defaults: defaults(), providerLoader: { id in
            await calls.record(id)
            return self.account(id)
        })
        monitor.menuBarStyle = .rings
        monitor.appearanceChanged()
        monitor.updateSlotColor(monitor.barSlots[0].id, color: .red)
        monitor.updateSlotTarget(monitor.barSlots[0].id, target: "battery")
        monitor.addSlot()
        monitor.moveSlot(monitor.barSlots[0].id, direction: 1)
        monitor.refreshMinutes = 1
        monitor.refreshIntervalChanged()
        monitor.alertThreshold = 5
        monitor.alertPreferencesChanged()
        monitor.appLanguage = .zh
        await Task.yield()
        let recorded = await calls.items
        XCTAssertTrue(recorded.isEmpty)
        monitor.stop()
    }

    @MainActor func testDisabledProvidersArePausedAndNeverFetchedEvenManually() async {
        let calls = RequestRecorder()
        let monitor = UsageMonitor(defaults: defaults(), providerLoader: { id in
            await calls.record(id)
            return self.account(id)
        })
        monitor.accounts = [account("chatgpt"), account("cursor"), account("claude")]
        monitor.cursorEnabled = false
        monitor.claudeEnabled = false
        monitor.providersChanged()
        XCTAssertEqual(monitor.accounts[1].state, .paused)
        monitor.reload(userInitiated: true)
        await monitor.waitForRefresh()
        let recorded = await calls.items
        XCTAssertEqual(recorded, ["chatgpt"])
        monitor.stop()
    }

    @MainActor func testServicesPublishBeforeSlowCursorFinishes() async {
        let monitor = UsageMonitor(defaults: defaults(), providerLoader: { id in
            if id == "cursor" { try? await Task.sleep(nanoseconds: 500_000_000) }
            return self.account(id)
        })
        monitor.reload(userInitiated: true)
        let deadline = Date().addingTimeInterval(2)
        while monitor.accounts.first(where: { $0.id == "chatgpt" })?.state != .current && Date() < deadline {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertEqual(monitor.accounts.first(where: { $0.id == "chatgpt" })?.state, .current)
        XCTAssertEqual(monitor.accounts.first(where: { $0.id == "cursor" })?.state, .loading)
        await monitor.waitForRefresh()
        XCTAssertEqual(monitor.accounts.first(where: { $0.id == "cursor" })?.state, .current)
        monitor.stop()
    }

    @MainActor func testOnboardingDoesNotReadCredentialsOrFetchBeforeConsent() async {
        let calls = RequestRecorder()
        let storage = defaults()
        storage.set(false, forKey: "onboardingComplete")
        let monitor = UsageMonitor(defaults: storage, providerLoader: { id in
            await calls.record(id)
            return self.account(id)
        })
        monitor.reload(userInitiated: true)
        await monitor.waitForRefresh()
        let recorded = await calls.items
        XCTAssertTrue(recorded.isEmpty)
        monitor.stop()
    }

    @MainActor func testSupersededRefreshCannotOverwriteNewerResults() async {
        let gate = FirstRequestGate()
        let monitor = UsageMonitor(defaults: defaults(), providerLoader: { id in
            let first = await gate.waitIfFirst()
            return self.account(id, remaining: first ? 10 : 80)
        })
        monitor.cursorEnabled = false
        monitor.claudeEnabled = false
        monitor.providersChanged()
        monitor.reload(userInitiated: true)
        while await gate.count == 0 { await Task.yield() }
        monitor.reload(userInitiated: true)
        await monitor.waitForRefresh()
        XCTAssertEqual(monitor.accounts.first?.windows.first?.remainingPercent, 80)
        await gate.release()
        try? await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertEqual(monitor.accounts.first?.windows.first?.remainingPercent, 80)
        monitor.stop()
    }

    @MainActor func testAccountSwitchClearsOnlyItsNotificationCycles() async {
        let storage = defaults()
        storage.set(["chatgpt.primary": 123, "cursor.cursor-total": 456], forKey: "alertedCycle")
        let monitor = UsageMonitor(defaults: storage, providerLoader: { id in
            var account = self.account(id)
            account.accountIdentity = "B"
            return account
        })
        var old = account("chatgpt")
        old.accountIdentity = "A"
        monitor.accounts[0] = old
        monitor.cursorEnabled = false
        monitor.claudeEnabled = false
        monitor.providersChanged()
        monitor.reload(userInitiated: true)
        await monitor.waitForRefresh()
        let cycles = storage.dictionary(forKey: "alertedCycle")!
        XCTAssertNil(cycles["chatgpt.primary"])
        XCTAssertEqual(cycles["cursor.cursor-total"] as? Int, 456)
        monitor.stop()
    }

    @MainActor func testHistoricalAndLocalReadingsCannotAlert() async {
        var account = account("chatgpt")
        account.state = .stale
        XCTAssertFalse(account.canAlert)
        account.state = .local
        account.origin = .localLog
        XCTAssertFalse(account.canAlert)
        XCTAssertTrue(UsageMonitor.wantsUsageAlert(remaining: 15, threshold: 20, hasAmountDetail: false, alreadyAlerted: false))
        for remaining in [0.0, 0.4, 40] {
            XCTAssertFalse(UsageMonitor.wantsUsageAlert(remaining: remaining, threshold: 20, hasAmountDetail: false, alreadyAlerted: false))
        }
        XCTAssertFalse(UsageMonitor.wantsUsageAlert(remaining: 15, threshold: 20, hasAmountDetail: true, alreadyAlerted: false))
        XCTAssertFalse(UsageMonitor.wantsUsageAlert(remaining: 15, threshold: 20, hasAmountDetail: false, alreadyAlerted: true))
    }
}

actor RequestRecorder {
    var items: [String] = []
    func record(_ item: String) { items.append(item) }
}

actor FirstRequestGate {
    var count = 0
    private var continuation: CheckedContinuation<Void, Never>?
    func waitIfFirst() async -> Bool {
        count += 1
        guard count == 1 else { return false }
        await withCheckedContinuation { continuation = $0 }
        return true
    }
    func release() { continuation?.resume(); continuation = nil }
}
