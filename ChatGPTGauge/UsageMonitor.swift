import AppKit
import Foundation
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
    private var powerObserver: NSObjectProtocol?

    init() {
        let defaults = UserDefaults.standard
        liveEnabled = defaults.object(forKey: Keys.liveEnabled) as? Bool ?? true
        refreshMinutes = defaults.object(forKey: Keys.refreshMinutes) as? Double ?? 5
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
        #endif
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
    }

    func setPopoverVisible(_ visible: Bool) {
        guard popoverVisible != visible else { return }
        popoverVisible = visible
        if visible { now = Date() }
        scheduleClock()
    }

    func reload(userInitiated: Bool) {
        reloadTask?.cancel()
        reloadTask = Task { await performReload(includeLive: liveEnabled, userInitiated: userInitiated) }
    }

    func savePreferences(scheduleRefresh: Bool = true) {
        let defaults = UserDefaults.standard
        defaults.set(liveEnabled, forKey: Keys.liveEnabled)
        defaults.set(refreshMinutes, forKey: Keys.refreshMinutes)
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

    private func shouldFetch(_ id: String, userInitiated: Bool, now: Date) -> Bool {
        if userInitiated { return true }
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

    private func performReload(includeLive: Bool, userInitiated: Bool) async {
        refreshPowerSaver()
        if userInitiated { isRefreshing = true }
        defer { if userInitiated { isRefreshing = false } }

        let moment = Date()
        let fetchChat = shouldFetch("chatgpt", userInitiated: userInitiated, now: moment)
        let fetchCursor = includeLive && shouldFetch("cursor", userInitiated: userInitiated, now: moment)
        let fetchClaude = includeLive && shouldFetch("claude", userInitiated: userInitiated, now: moment)

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
        if let chat, !chat.windows.isEmpty { considerAlerts(for: chat) }
        if let cursor, !cursor.windows.isEmpty { considerAlerts(for: cursor) }
        if let claude, !claude.windows.isEmpty { considerAlerts(for: claude) }
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

    private func considerAlerts(for account: ProviderAccount) {
        guard alertsEnabled else { return }
        if !askedForAlerts {
            askedForAlerts = true
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        }

        var stored: [String: Double] = [:]
        if let raw = UserDefaults.standard.dictionary(forKey: Keys.alertedReset) {
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
            guard stored[key] != resetKey else { continue }
            stored[key] = resetKey
            changed = true
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
            UNUserNotificationCenter.current().add(request)
        }
        if changed {
            UserDefaults.standard.set(stored, forKey: Keys.alertedReset)
        }
    }

    private enum Keys {
        static let liveEnabled = "liveEnabled"
        static let refreshMinutes = "refreshMinutes"
        static let batteryMinutes = "batteryMinutes"
        static let alertsEnabled = "alertsEnabled"
        static let alertThreshold = "alertThreshold"
        static let alertedReset = "alertedReset"
        static let showBattery = "showBattery"
        static let menuBarStyle = "menuBarStyle"
        static let barSlots = "barSlots"
        static let appLanguage = "appLanguage"
        static let menuBarOffset = "menuBarOffset"
        static let menuTextTemplate = "menuTextTemplate"
        static let batteryMark = "batteryMark"
    }
}
