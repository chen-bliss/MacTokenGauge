import AppKit
import Foundation
import IOKit.pwr_mgt
import SwiftUI
import UserNotifications

@MainActor
final class UsageMonitor: ObservableObject {
    @Published var accounts: [ProviderAccount] = ProviderAccount.placeholders
    @Published var battery: BatteryReading?
    @Published var now = Date()
    @Published var isRefreshing = false
    @Published var liveEnabled: Bool
    @Published var refreshMinutes: Double
    @Published var refreshOnWake: Bool
    @Published var batteryMinutes: Double
    @Published private(set) var powerSaver = false
    @Published var alertsEnabled: Bool
    @Published var alertThreshold: Double
    @Published var showBattery: Bool
    @Published var menuBarStyle: MenuBarStyle
    @Published var barSlots: [BarSlot]
    @Published var appLanguage: AppLanguage {
        didSet {
            guard appLanguage != oldValue else { return }
            L10n.language = appLanguage
            savePreferences(scheduleRefresh: false)
            SettingsPresenter.retitle()
            reload(userInitiated: false)
        }
    }
    @Published var menuTextTemplate: String {
        didSet {
            let trimmed = String(menuTextTemplate.prefix(160))
            if trimmed != menuTextTemplate {
                menuTextTemplate = trimmed
                return
            }
            guard menuTextTemplate != oldValue else { return }
            savePreferences(scheduleRefresh: false)
        }
    }
    @Published var batteryMark: BatteryMark {
        didSet {
            guard batteryMark != oldValue else { return }
            savePreferences(scheduleRefresh: false)
        }
    }
    @Published var menuBarOffset: Double {
        didSet {
            let clamped = min(Self.maxMenuBarOffset, max(0, menuBarOffset))
            if clamped != menuBarOffset {
                menuBarOffset = clamped
                return
            }
            guard menuBarOffset != oldValue else { return }
            savePreferences(scheduleRefresh: false)
        }
    }

    static var maxMenuBarOffset: Double {
        let width = NSScreen.main?.frame.width ?? 1440
        return max(280, width - 360)
    }

    private var started = false
    private var clockTimer: Timer?
    private var batteryTimer: Timer?
    private var refreshTimer: Timer?
    private var reloadTask: Task<Void, Never>?
    private var popoverVisible = false
    private var askedForAlerts = false
    private let notificationPoster = UsageNotificationDelegate()
    private var powerObserver: NSObjectProtocol?
    private var screenWake: ScreenWakeHub?
    private var lastWakeRefresh = Date.distantPast

    init() {
        let defaults = UserDefaults.standard
        liveEnabled = defaults.object(forKey: Keys.liveEnabled) as? Bool ?? true
        refreshMinutes = defaults.object(forKey: Keys.refreshMinutes) as? Double ?? 5
        refreshOnWake = defaults.object(forKey: Keys.refreshOnWake) as? Bool ?? true
        batteryMinutes = defaults.object(forKey: Keys.batteryMinutes) as? Double ?? 2
        alertsEnabled = defaults.object(forKey: Keys.alertsEnabled) as? Bool ?? true
        alertThreshold = defaults.object(forKey: Keys.alertThreshold) as? Double ?? 20
        showBattery = defaults.object(forKey: Keys.showBattery) as? Bool ?? true
        menuBarStyle = MenuBarStyle(rawValue: defaults.string(forKey: Keys.menuBarStyle) ?? "") ?? .text
        let language = AppLanguage(rawValue: defaults.string(forKey: Keys.appLanguage) ?? "") ?? .system
        appLanguage = language
        menuBarOffset = defaults.object(forKey: Keys.menuBarOffset) as? Double ?? 0
        let storedTemplate = defaults.string(forKey: Keys.menuTextTemplate) ?? ""
        menuTextTemplate = storedTemplate.isEmpty ? "{name} {percent} {countdown}" : storedTemplate
        batteryMark = BatteryMark(rawValue: defaults.string(forKey: Keys.batteryMark) ?? "") ?? .icon
        if let data = defaults.data(forKey: Keys.barSlots),
           let slots = try? JSONDecoder().decode([BarSlot].self, from: data),
           !slots.isEmpty {
            barSlots = slots
        } else {
            barSlots = BarSlot.defaults
        }
        L10n.language = language
        Task { @MainActor in
            self.start()
        }
    }

    func start() {
        guard !started else { return }
        started = true
        #if DEBUG
        UsageParser.selfCheck()
        CursorUsageClient.selfCheck()
        Self.selfCheckAlerts()
        #endif
        UNUserNotificationCenter.current().delegate = notificationPoster
        battery = BatteryReader.current()
        refreshPowerSaver(reschedule: false)
        reload(userInitiated: false)
        scheduleClock()
        scheduleBattery()
        powerObserver = NotificationCenter.default.addObserver(
            forName: .NSProcessInfoPowerStateDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refreshPowerSaver()
            }
        }
        observeScreenWake()
    }

    /// Launch always loads usage once. This switch only adds a refresh when the screen turns on later.
    private func observeScreenWake() {
        lastWakeRefresh = Date()
        screenWake = ScreenWakeHub { [weak self] in
            Task { @MainActor in
                self?.refreshAfterScreenWake()
            }
        }
    }

    private func refreshAfterScreenWake() {
        guard refreshOnWake else { return }
        let moment = Date()
        guard moment.timeIntervalSince(lastWakeRefresh) > 3 else { return }
        lastWakeRefresh = moment
        reload(userInitiated: false, ignorePause: true)
    }

    func setPopoverVisible(_ visible: Bool) {
        guard popoverVisible != visible else { return }
        popoverVisible = visible
        if visible { now = Date() }
        scheduleClock()
    }

    func reload(userInitiated: Bool, ignorePause: Bool = false) {
        reloadTask?.cancel()
        reloadTask = Task { await performReload(includeLive: liveEnabled, userInitiated: userInitiated, ignorePause: ignorePause) }
    }

    func savePreferences(scheduleRefresh: Bool = true) {
        let defaults = UserDefaults.standard
        defaults.set(liveEnabled, forKey: Keys.liveEnabled)
        defaults.set(refreshMinutes, forKey: Keys.refreshMinutes)
        defaults.set(refreshOnWake, forKey: Keys.refreshOnWake)
        defaults.set(batteryMinutes, forKey: Keys.batteryMinutes)
        defaults.set(alertsEnabled, forKey: Keys.alertsEnabled)
        defaults.set(alertThreshold, forKey: Keys.alertThreshold)
        defaults.set(showBattery, forKey: Keys.showBattery)
        defaults.set(menuBarStyle.rawValue, forKey: Keys.menuBarStyle)
        defaults.set(appLanguage.rawValue, forKey: Keys.appLanguage)
        defaults.set(menuBarOffset, forKey: Keys.menuBarOffset)
        defaults.set(menuTextTemplate, forKey: Keys.menuTextTemplate)
        defaults.set(batteryMark.rawValue, forKey: Keys.batteryMark)
        if let data = try? JSONEncoder().encode(barSlots) {
            defaults.set(data, forKey: Keys.barSlots)
        }
        scheduleClock()
        scheduleBattery()
        if scheduleRefresh { reload(userInitiated: false) }
    }

    func updateSlotTarget(_ id: UUID, target: String) {
        guard let index = barSlots.firstIndex(where: { $0.id == id }) else { return }
        barSlots[index].target = target
        savePreferences()
    }

    func updateSlotColor(_ id: UUID, color: Color) {
        guard let index = barSlots.firstIndex(where: { $0.id == id }) else { return }
        barSlots[index].colorHex = ColorHex.hex(from: color)
        savePreferences()
    }

    func moveSlot(_ id: UUID, direction: Int) {
        guard let index = barSlots.firstIndex(where: { $0.id == id }) else { return }
        let next = index + direction
        guard barSlots.indices.contains(next) else { return }
        barSlots.swapAt(index, next)
        savePreferences()
    }

    func removeSlot(_ id: UUID) {
        guard barSlots.count > 1 else { return }
        barSlots.removeAll { $0.id == id }
        savePreferences()
    }

    func addSlot() {
        guard barSlots.count < 6 else { return }
        let used = Set(barSlots.map(\.target))
        let target = BarTarget.catalog.first { !used.contains($0.id) }?.id ?? "battery"
        barSlots.append(BarSlot(id: UUID(), target: target, colorHex: "5B8DEF"))
        savePreferences()
    }

    private var clockNeeded: Bool {
        popoverVisible || menuBarStyle == .text
    }

    private func scheduleBattery() {
        batteryTimer?.invalidate()
        batteryTimer = nil
        guard showBattery || menuBarStyle == .battery else { return }
        let interval = batteryCheckInterval
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tickBattery() }
        }
        timer.tolerance = powerSaver ? min(180, interval * 0.3) : min(60, interval * 0.5)
        RunLoop.main.add(timer, forMode: .common)
        batteryTimer = timer
    }

    private func tickBattery() {
        refreshPowerSaver()
        guard showBattery || menuBarStyle == .battery else { return }
        let reading = BatteryReader.current()
        guard reading != battery else { return }
        battery = reading
    }

    private var batteryCheckInterval: TimeInterval {
        let chosen = max(60, batteryMinutes * 60)
        guard powerSaver else { return chosen }
        return max(chosen * 3, 10 * 60)
    }

    private func scheduleClock() {
        clockTimer?.invalidate()
        clockTimer = nil
        guard clockNeeded else { return }
        let interval = clockInterval
        let fire: Date
        if powerSaver {
            fire = Date().addingTimeInterval(interval)
        } else {
            let now = Date()
            fire = Calendar.current.nextDate(
                after: now,
                matching: DateComponents(second: 0),
                matchingPolicy: .nextTime
            ) ?? now.addingTimeInterval(interval)
        }
        let timer = Timer(fire: fire, interval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tickClock() }
        }
        timer.tolerance = powerSaver ? min(120, interval * 0.3) : (popoverVisible ? 5 : 30)
        RunLoop.main.add(timer, forMode: .common)
        clockTimer = timer
    }

    private var clockInterval: TimeInterval {
        guard powerSaver else { return 60 }
        return popoverVisible ? 120 : 300
    }

    private func refreshPowerSaver(reschedule: Bool = true) {
        let active = ProcessInfo.processInfo.isLowPowerModeEnabled || BatteryReader.isLowBatteryWarning()
        guard active != powerSaver else { return }
        powerSaver = active
        guard reschedule else { return }
        scheduleClock()
        scheduleBattery()
        scheduleRefresh()
    }

    private func tickClock() {
        refreshPowerSaver()
        let next = Date()
        guard Calendar.current.compare(now, to: next, toGranularity: .minute) != .orderedSame else { return }
        now = next
    }

    private func scheduleRefresh() {
        refreshTimer?.invalidate()
        let delay = nextRefreshDelay()
        let timer = Timer(fire: Date().addingTimeInterval(delay), interval: 0, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.reload(userInitiated: false)
            }
        }
        timer.tolerance = min(180, max(20, delay * 0.02))
        RunLoop.main.add(timer, forMode: .common)
        refreshTimer = timer
    }

    private func nextRefreshDelay(now: Date = Date()) -> TimeInterval {
        let interval = TimeInterval(liveInterval)
        var delays: [TimeInterval] = []
        for id in ["chatgpt", "cursor", "claude"] {
            if id != "chatgpt", !liveEnabled { continue }
            guard let account = accounts.first(where: { $0.id == id }) else {
                delays.append(interval)
                continue
            }
            if let resume = Self.resumeAt(account, now: now), resume > now {
                delays.append(resume.timeIntervalSince(now))
            } else {
                delays.append(interval)
            }
        }
        return min(max(delays.min() ?? interval, 30), 24 * 60 * 60)
    }

    /// When the window that actually blocks more use is empty, wait until it resets
    /// instead of polling the network on the normal interval.
    private static func resumeAt(_ account: ProviderAccount, now: Date) -> Date? {
        let gates = gatingWindows(account)
        guard !gates.isEmpty, gates.allSatisfy({ $0.remainingPercent <= 0.5 }) else { return nil }
        guard gates.allSatisfy({ $0.resetAt != nil }) else { return nil }
        let future = gates.compactMap(\.resetAt).filter { $0 > now }
        guard let earliest = future.min() else { return nil }
        return earliest.addingTimeInterval(20)
    }

    private static func gatingWindows(_ account: ProviderAccount) -> [UsageWindow] {
        switch account.id {
        case "chatgpt":
            return account.windows.filter { $0.id == "primary" }
        case "claude":
            return account.windows.filter { $0.id == "five_hour" }
        case "cursor":
            if let extra = account.windows.first(where: { $0.id == "cursor-ondemand" }),
               extra.detail != nil || extra.remainingPercent > 0.5 {
                return []
            }
            return account.windows.filter { ["cursor-total", "cursor-auto", "cursor-api"].contains($0.id) }
        default:
            return []
        }
    }

    private static func loadIfNeeded(_ needed: Bool, _ load: () async -> ProviderAccount) async -> ProviderAccount? {
        guard needed else { return nil }
        return await load()
    }

    private func shouldFetch(_ id: String, userInitiated: Bool, ignorePause: Bool, now: Date) -> Bool {
        if userInitiated || ignorePause { return true }
        if id != "chatgpt", !liveEnabled { return false }
        guard let account = accounts.first(where: { $0.id == id }), !account.windows.isEmpty else { return true }
        if let resume = Self.resumeAt(account, now: now) {
            return resume <= now
        }
        return true
    }

    private var liveInterval: Int {
        let chosen = max(60, Int(refreshMinutes * 60))
        guard powerSaver else { return chosen }
        return max(chosen * 3, 15 * 60)
    }

    private func performReload(includeLive: Bool, userInitiated: Bool, ignorePause: Bool) async {
        refreshPowerSaver()
        if userInitiated { isRefreshing = true }
        defer { if userInitiated { isRefreshing = false } }

        let moment = Date()
        let fetchChat = shouldFetch("chatgpt", userInitiated: userInitiated, ignorePause: ignorePause, now: moment)
        let fetchCursor = includeLive && shouldFetch("cursor", userInitiated: userInitiated, ignorePause: ignorePause, now: moment)
        let fetchClaude = includeLive && shouldFetch("claude", userInitiated: userInitiated, ignorePause: ignorePause, now: moment)

        async let chatTask = Self.loadIfNeeded(fetchChat) { await ChatGPTAccountLoader.load(includeLive: true) }
        async let cursorTask = Self.loadIfNeeded(fetchCursor) { await CursorAccountLoader.load() }
        async let claudeTask = Self.loadIfNeeded(fetchClaude) { await ClaudeAccountLoader.load() }
        let chat = await chatTask
        let cursor = await cursorTask
        let claude = await claudeTask
        if Task.isCancelled { return }

        var next = accounts
        if let chat { merge(chat, into: &next) }
        if let cursor { merge(cursor, into: &next) }
        if let claude { merge(claude, into: &next) }
        accounts = next
        if let chat, !chat.windows.isEmpty { await considerAlerts(for: chat) }
        if let cursor, !cursor.windows.isEmpty { await considerAlerts(for: cursor) }
        if let claude, !claude.windows.isEmpty { await considerAlerts(for: claude) }
        scheduleRefresh()
    }

    private func merge(_ fresh: ProviderAccount, into list: inout [ProviderAccount]) {
        guard let index = list.firstIndex(where: { $0.id == fresh.id }) else {
            list.append(fresh)
            return
        }
        if fresh.origin == .localLog, list[index].origin == .live, !list[index].windows.isEmpty {
            return
        }
        if fresh.windows.isEmpty, !list[index].windows.isEmpty {
            var kept = list[index]
            kept.status = fresh.status
            list[index] = kept
            return
        }
        list[index] = fresh
    }

    /// Alert only while some quota is still left. A window that is already used up
    /// does not need a reminder, and an uncapped spend row is not a percent.
    static func wantsUsageAlert(remaining: Double, threshold: Double, hasAmountDetail: Bool, alreadyAlerted: Bool) -> Bool {
        if hasAmountDetail || alreadyAlerted { return false }
        if remaining <= 0.5 { return false }
        return remaining <= threshold
    }

    private static func selfCheckAlerts() {
        precondition(wantsUsageAlert(remaining: 15, threshold: 20, hasAmountDetail: false, alreadyAlerted: false))
        precondition(!wantsUsageAlert(remaining: 0, threshold: 20, hasAmountDetail: false, alreadyAlerted: false))
        precondition(!wantsUsageAlert(remaining: 0.4, threshold: 20, hasAmountDetail: false, alreadyAlerted: false))
        precondition(!wantsUsageAlert(remaining: 40, threshold: 20, hasAmountDetail: false, alreadyAlerted: false))
        precondition(!wantsUsageAlert(remaining: 15, threshold: 20, hasAmountDetail: false, alreadyAlerted: true))
        precondition(!wantsUsageAlert(remaining: 8, threshold: 20, hasAmountDetail: true, alreadyAlerted: false))
        precondition(wantsUsageAlert(remaining: 5, threshold: 5, hasAmountDetail: false, alreadyAlerted: false))
        precondition(!wantsUsageAlert(remaining: 21, threshold: 20, hasAmountDetail: false, alreadyAlerted: false))
    }

    private func considerAlerts(for account: ProviderAccount) async {
        guard alertsEnabled else { return }
        guard await notificationsAllowed() else { return }

        var stored: [String: Double] = [:]
        if let raw = UserDefaults.standard.dictionary(forKey: Keys.alertedCycle) {
            for (key, value) in raw {
                if let number = value as? NSNumber {
                    stored[key] = number.doubleValue
                }
            }
        }
        var changed = false
        for window in account.windows {
            let key = "\(account.id).\(window.id)"
            let resetKey = window.resetAt?.timeIntervalSince1970 ?? -1
            if window.remainingPercent > alertThreshold + 2 {
                if stored.removeValue(forKey: key) != nil { changed = true }
                continue
            }
            let already = stored[key] == resetKey
            guard Self.wantsUsageAlert(
                remaining: window.remainingPercent,
                threshold: alertThreshold,
                hasAmountDetail: window.detail != nil,
                alreadyAlerted: already
            ) else { continue }
            let content = UNMutableNotificationContent()
            let title = L10n.windowTitle(window)
            content.title = L10n.f(.alertTitle, account.name)
            if let resetAt = window.resetAt {
                content.body = L10n.f(.alertBody, title, Int(window.remainingPercent.rounded()), UsageFormatting.longCountdown(until: resetAt, now: Date()))
            } else {
                content.body = L10n.f(.alertBodyPlain, title, Int(window.remainingPercent.rounded()))
            }
            content.sound = .default
            let request = UNNotificationRequest(
                identifier: "usage-\(key)-\(Int(resetKey))",
                content: content,
                trigger: nil
            )
            guard await deliver(request) else { continue }
            stored[key] = resetKey
            changed = true
        }
        if changed {
            UserDefaults.standard.set(stored, forKey: Keys.alertedCycle)
        }
    }

    private func notificationsAllowed() async -> Bool {
        let settings = await withCheckedContinuation { (continuation: CheckedContinuation<UNNotificationSettings, Never>) in
            UNUserNotificationCenter.current().getNotificationSettings { continuation.resume(returning: $0) }
        }
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            return true
        case .denied:
            return false
        case .notDetermined:
            guard !askedForAlerts else { return false }
            askedForAlerts = true
            return await requestNotificationPermission()
        @unknown default:
            return false
        }
    }

    /// An accessory app does not get the permission dialog unless it is briefly a normal app.
    private func requestNotificationPermission() async -> Bool {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        let granted: Bool
        do {
            granted = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
        } catch {
            granted = false
        }
        NSApp.setActivationPolicy(.accessory)
        return granted
    }

    private func deliver(_ request: UNNotificationRequest) async -> Bool {
        await withCheckedContinuation { continuation in
            UNUserNotificationCenter.current().add(request) { error in
                continuation.resume(returning: error == nil)
            }
        }
    }

    private enum Keys {
        static let liveEnabled = "liveEnabled"
        static let refreshMinutes = "refreshMinutes"
        static let refreshOnWake = "refreshOnWake"
        static let batteryMinutes = "batteryMinutes"
        static let alertsEnabled = "alertsEnabled"
        static let alertThreshold = "alertThreshold"
        static let alertedCycle = "alertedCycle"
        static let showBattery = "showBattery"
        static let menuBarStyle = "menuBarStyle"
        static let barSlots = "barSlots"
        static let appLanguage = "appLanguage"
        static let menuBarOffset = "menuBarOffset"
        static let menuTextTemplate = "menuTextTemplate"
        static let batteryMark = "batteryMark"
    }
}

private final class UsageNotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list, .sound])
    }
}

private typealias NotifyHandler = @convention(block) (Int32) -> Void

@_silgen_name("notify_register_dispatch")
private func notify_register_dispatch(
    _ name: UnsafePointer<CChar>,
    _ token: UnsafeMutablePointer<Int32>,
    _ queue: DispatchQueue,
    _ handler: @escaping NotifyHandler
) -> UInt32

@_silgen_name("notify_get_state")
private func notify_get_state(_ token: Int32, _ state: UnsafeMutablePointer<UInt64>) -> UInt32

// IOMessage.h macros are not visible to Swift. These match iokit_common_msg values.
private let ioMessageCanSystemSleep: UInt32 = 0xE000_0270
private let ioMessageSystemWillSleep: UInt32 = 0xE000_0280
private let ioMessageSystemHasPoweredOn: UInt32 = 0xE000_0300

/// Menu bar apps often miss block-based NSWorkspace wake notifications after sleep.
/// This listens on the main thread, and also watches display power and system wake.
private final class ScreenWakeHub: NSObject {
    private let onWake: () -> Void
    private var powerPort: io_connect_t = 0
    private var notifyPort: IONotificationPortRef?
    private var powerNotifier: io_object_t = 0
    private var displayNotifyToken: Int32 = 0
    private var primedDisplayStatus = false

    init(onWake: @escaping () -> Void) {
        self.onWake = onWake
        super.init()
        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(self, selector: #selector(handleWake(_:)), name: NSWorkspace.didWakeNotification, object: nil)
        workspace.addObserver(self, selector: #selector(handleWake(_:)), name: NSWorkspace.screensDidWakeNotification, object: nil)
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(handleWake(_:)),
            name: Notification.Name("com.apple.screenIsUnlocked"),
            object: nil,
            suspensionBehavior: .deliverImmediately
        )
        registerDisplayStatus()
        registerSystemPower()
    }

    @objc private func handleWake(_ notification: Notification) {
        onWake()
    }

    private func registerDisplayStatus() {
        notify_register_dispatch("com.apple.iokit.hid.displayStatus", &displayNotifyToken, .main) { [weak self] token in
            guard let self else { return }
            var state: UInt64 = 0
            notify_get_state(token, &state)
            if !self.primedDisplayStatus {
                self.primedDisplayStatus = true
                return
            }
            guard state != 0 else { return }
            self.onWake()
        }
    }

    private func registerSystemPower() {
        var port: IONotificationPortRef?
        powerPort = IORegisterForSystemPower(
            Unmanaged.passUnretained(self).toOpaque(),
            &port,
            { context, _, messageType, messageArgument in
                guard let context else { return }
                let hub = Unmanaged<ScreenWakeHub>.fromOpaque(context).takeUnretainedValue()
                hub.handlePower(messageType, messageArgument)
            },
            &powerNotifier
        )
        notifyPort = port
        guard powerPort != 0, let port else { return }
        CFRunLoopAddSource(CFRunLoopGetMain(), IONotificationPortGetRunLoopSource(port).takeUnretainedValue(), .commonModes)
    }

    private func handlePower(_ messageType: UInt32, _ messageArgument: UnsafeMutableRawPointer?) {
        switch messageType {
        case ioMessageCanSystemSleep, ioMessageSystemWillSleep:
            guard let messageArgument else { return }
            IOAllowPowerChange(powerPort, Int(bitPattern: messageArgument))
        case ioMessageSystemHasPoweredOn:
            onWake()
        default:
            break
        }
    }
}
