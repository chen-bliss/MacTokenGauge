import AppKit
import Foundation
import IOKit.pwr_mgt
import SwiftUI
import UserNotifications

@MainActor
final class UsageMonitor: ObservableObject {
    @Published var checkingUpdates = false
    @Published var updateResult: UpdateResult?
    @Published var accounts: [ProviderAccount] = ProviderAccount.placeholders
    @Published var battery: BatteryReading?
    @Published var now = Date()
    @Published var isRefreshing = false
    @Published var onboardingComplete: Bool
    @Published var chatgptEnabled: Bool
    @Published var cursorEnabled: Bool
    @Published var claudeEnabled: Bool
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

    private let defaults: UserDefaults
    private let providerLoader: @Sendable (String) async -> ProviderAccount
    private var reloadGeneration = 0
    private var started = false
    private var clockTimer: Timer?
    private var batteryTimer: Timer?
    private var refreshTimer: Timer?
    private var reloadTask: Task<Void, Never>?
    private var popoverVisible = false
    private var askedForAlerts = false
    private var evaluatingAlerts: Set<String> = []
    private var pendingAlerts: Set<String> = []
    private let notificationPoster = UsageNotificationDelegate()
    private var powerObserver: NSObjectProtocol?
    private var screenWake: ScreenWakeHub?
    private var lastWakeRefresh = Date.distantPast

    init(defaults: UserDefaults = .standard,
         providerLoader: @escaping @Sendable (String) async -> ProviderAccount = { await UsageMonitor.loadProvider($0) }) {
        self.defaults = defaults
        self.providerLoader = providerLoader
        onboardingComplete = defaults.object(forKey: "onboardingComplete") as? Bool ?? (defaults.object(forKey: Keys.refreshMinutes) != nil)
        chatgptEnabled = defaults.object(forKey: Keys.chatgptEnabled) as? Bool ?? true
        cursorEnabled = defaults.object(forKey: Keys.cursorEnabled) as? Bool ?? defaults.object(forKey: "liveEnabled") as? Bool ?? true
        claudeEnabled = defaults.object(forKey: Keys.claudeEnabled) as? Bool ?? defaults.object(forKey: "liveEnabled") as? Bool ?? true
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
    }

    func stop() {
        reloadGeneration += 1
        reloadTask?.cancel()
        reloadTask = nil
        clockTimer?.invalidate()
        batteryTimer?.invalidate()
        refreshTimer?.invalidate()
        clockTimer = nil
        batteryTimer = nil
        refreshTimer = nil
        if let powerObserver { NotificationCenter.default.removeObserver(powerObserver) }
        powerObserver = nil
        screenWake = nil
        started = false
    }

    func start() {
        guard !started else { return }
        started = true
        UNUserNotificationCenter.current().delegate = notificationPoster
        battery = BatteryReader.current()
        refreshPowerSaver(reschedule: false)
        markPausedProviders()
        if onboardingComplete { reload(userInitiated: false) }
        else { SettingsPresenter.show(monitor: self) }
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
        guard onboardingComplete else { return }
        reloadTask?.cancel()
        reloadGeneration += 1
        let generation = reloadGeneration
        reloadTask = Task { await performReload(userInitiated: userInitiated, ignorePause: ignorePause, generation: generation) }
    }

    func savePreferences(scheduleRefresh: Bool = false) {
        defaults.set(onboardingComplete, forKey: "onboardingComplete")
        defaults.set(chatgptEnabled, forKey: Keys.chatgptEnabled)
        defaults.set(cursorEnabled, forKey: Keys.cursorEnabled)
        defaults.set(claudeEnabled, forKey: Keys.claudeEnabled)
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
        if scheduleRefresh { self.scheduleRefresh() }
    }

    func appearanceChanged() {
        savePreferences()
        scheduleClock()
        tickBattery()
        scheduleBattery()
    }

    func refreshIntervalChanged() {
        savePreferences()
        if started { scheduleRefresh() }
    }

    func alertPreferencesChanged() {
        savePreferences()
        Task { for account in accounts where account.canAlert { await considerAlerts(for: account) } }
    }

    func isEnabled(_ id: String) -> Bool {
        switch id {
        case "chatgpt": return chatgptEnabled
        case "cursor": return cursorEnabled
        case "claude": return claudeEnabled
        default: return false
        }
    }

    func completeOnboarding() {
        onboardingComplete = true
        savePreferences()
        markPausedProviders()
        reload(userInitiated: false)
    }

    func providersChanged() {
        savePreferences()
        markPausedProviders()
        if started { reload(userInitiated: false, ignorePause: true) }
    }

    private func markPausedProviders() {
        for index in accounts.indices {
            if !isEnabled(accounts[index].id) {
                accounts[index].state = .paused
            } else if accounts[index].state == .paused {
                accounts[index].state = accounts[index].windows.isEmpty ? .loading : .stale
            }
        }
    }

    nonisolated private static func loadProvider(_ id: String) async -> ProviderAccount {
        switch id {
        case "chatgpt": return await ChatGPTAccountLoader.load(includeLive: true)
        case "cursor": return await CursorAccountLoader.load()
        default: return await ClaudeAccountLoader.load()
        }
    }

    func updateSlotTarget(_ id: UUID, target: String) {
        guard let index = barSlots.firstIndex(where: { $0.id == id }) else { return }
        barSlots[index].target = target
        appearanceChanged()
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
        appearanceChanged()
    }

    func addSlot() {
        guard barSlots.count < 6 else { return }
        let used = Set(barSlots.map(\.target))
        let target = BarTarget.catalog.first { !used.contains($0.id) }?.id ?? "battery"
        barSlots.append(BarSlot(id: UUID(), target: target, colorHex: "5B8DEF"))
        appearanceChanged()
    }

    private var clockNeeded: Bool {
        popoverVisible || menuBarStyle == .text
    }

    var batteryNeeded: Bool {
        Self.batteryNeeded(showBattery: showBattery, style: menuBarStyle, slots: barSlots)
    }

    static func batteryNeeded(showBattery: Bool, style: MenuBarStyle, slots: [BarSlot]) -> Bool {
        showBattery || style == .battery || ([.bars, .rings, .combined].contains(style) && slots.contains { $0.target == "battery" })
    }

    private func scheduleBattery() {
        batteryTimer?.invalidate()
        batteryTimer = nil
        guard batteryNeeded else { return }
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
        guard batteryNeeded else { return }
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
        refreshTimer = nil
        guard onboardingComplete, ["chatgpt", "cursor", "claude"].contains(where: isEnabled) else { return }
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
        let enabled = Set(["chatgpt", "cursor", "claude"].filter(isEnabled))
        return RefreshPolicy.nextDelay(accounts: accounts, enabled: enabled,
            interval: RefreshPolicy.interval(minutes: refreshMinutes, powerSaver: powerSaver), now: now)
    }

    private func shouldFetch(_ id: String, userInitiated: Bool, ignorePause: Bool, now: Date) -> Bool {
        RefreshPolicy.shouldFetch(account: accounts.first { $0.id == id }, enabled: isEnabled(id),
                                  force: userInitiated || ignorePause, now: now)
    }

    private func performReload(userInitiated: Bool, ignorePause: Bool, generation: Int) async {
        refreshPowerSaver()
        if userInitiated { isRefreshing = true }
        defer {
            if generation == reloadGeneration {
                isRefreshing = false
                scheduleRefresh()
            }
        }
        let moment = Date()
        let ids = ["chatgpt", "cursor", "claude"].filter {
            shouldFetch($0, userInitiated: userInitiated, ignorePause: ignorePause, now: moment)
        }
        let loader = providerLoader
        await withTaskGroup(of: ProviderAccount.self) { group in
            for id in ids { group.addTask { await loader(id) } }
            for await fresh in group {
                guard !Task.isCancelled, generation == reloadGeneration, isEnabled(fresh.id) else { continue }
                let previous = accounts.first { $0.id == fresh.id }
                if previous?.accountIdentity != fresh.accountIdentity {
                    clearAlertCycles(for: fresh.id)
                }
                let merged = ProviderAccount.merging(fresh, previous: previous)
                if let index = accounts.firstIndex(where: { $0.id == fresh.id }) { accounts[index] = merged }
                else { accounts.append(merged) }
                // Publish each service as soon as it arrives. Notifications cannot delay publication.
                Task { await considerAlerts(for: merged) }
            }
        }
    }

    private func clearAlertCycles(for id: String) {
        let cycles = defaults.dictionary(forKey: Keys.alertedCycle) ?? [:]
        defaults.set(cycles.filter { !$0.key.hasPrefix(id + ".") }, forKey: Keys.alertedCycle)
    }

    func waitForRefresh() async { await reloadTask?.value }

    /// Alert only while some quota is still left. A window that is already used up
    /// does not need a reminder, and an uncapped spend row is not a percent.
    static func wantsUsageAlert(remaining: Double, threshold: Double, hasAmountDetail: Bool, alreadyAlerted: Bool) -> Bool {
        if hasAmountDetail || alreadyAlerted { return false }
        if remaining <= 0.5 { return false }
        return remaining <= threshold
    }

    private func considerAlerts(for account: ProviderAccount) async {
        guard !evaluatingAlerts.contains(account.id) else { return }
        evaluatingAlerts.insert(account.id)
        defer { evaluatingAlerts.remove(account.id) }
        guard alertsEnabled, account.canAlert, isEnabled(account.id),
              let captured = account.capturedAt,
              Date().timeIntervalSince(captured) < max(600, refreshMinutes * 120) else { return }
        guard await notificationsAllowed() else { return }
        guard accounts.first(where: { $0.id == account.id }) == account else { return }

        var stored: [String: Double] = [:]
        if let raw = defaults.dictionary(forKey: Keys.alertedCycle) {
            for (key, value) in raw {
                if let number = value as? NSNumber {
                    stored[key] = number.doubleValue
                }
            }
        }
        var changed = false
        for window in account.windows where window.isQuota {
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
            let pendingKey = "\(key).\(resetKey)"
            guard !pendingAlerts.contains(pendingKey) else { continue }
            pendingAlerts.insert(pendingKey)
            let delivered = await deliver(request)
            pendingAlerts.remove(pendingKey)
            guard delivered, accounts.first(where: { $0.id == account.id })?.accountIdentity == account.accountIdentity,
                  isEnabled(account.id) else { continue }
            stored[key] = resetKey
            changed = true
        }
        if changed {
            var latest = defaults.dictionary(forKey: Keys.alertedCycle) ?? [:]
            for key in latest.keys where key.hasPrefix(account.id + ".") { latest.removeValue(forKey: key) }
            for (key, value) in stored where key.hasPrefix(account.id + ".") { latest[key] = value }
            defaults.set(latest, forKey: Keys.alertedCycle)
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
        static let chatgptEnabled = "chatgptEnabled"
        static let cursorEnabled = "cursorEnabled"
        static let claudeEnabled = "claudeEnabled"
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

@_silgen_name("notify_cancel")
private func notify_cancel(_ token: Int32) -> UInt32

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

    deinit {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        DistributedNotificationCenter.default().removeObserver(self)
        if displayNotifyToken != 0 { _ = notify_cancel(displayNotifyToken) }
        if powerNotifier != 0 { IODeregisterForSystemPower(&powerNotifier) }
        if powerPort != 0 { IOServiceClose(powerPort) }
        if let notifyPort { IONotificationPortDestroy(notifyPort) }
    }

    @objc private func handleWake(_ notification: Notification) {
        onWake()
    }

    private func registerDisplayStatus() {
        _ = notify_register_dispatch("com.apple.iokit.hid.displayStatus", &displayNotifyToken, .main) { [weak self] token in
            guard let self else { return }
            var state: UInt64 = 0
            _ = notify_get_state(token, &state)
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
