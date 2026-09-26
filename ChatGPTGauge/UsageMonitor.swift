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
    private var timer: Timer?
    private var reloadTask: Task<Void, Never>?
    private var secondsUntilLive = 0

    init() {
        let defaults = UserDefaults.standard
        liveEnabled = defaults.object(forKey: Keys.liveEnabled) as? Bool ?? true
        refreshMinutes = defaults.object(forKey: Keys.refreshMinutes) as? Double ?? 5
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
        #endif
        secondsUntilLive = liveInterval
        battery = BatteryReader.current()
        reload(userInitiated: false)
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.tick()
            }
        }
    }

    func reload(userInitiated: Bool) {
        reloadTask?.cancel()
        reloadTask = Task { await performReload(includeLive: liveEnabled, userInitiated: userInitiated) }
    }

    func savePreferences(scheduleRefresh: Bool = true) {
        let defaults = UserDefaults.standard
        defaults.set(liveEnabled, forKey: Keys.liveEnabled)
        defaults.set(refreshMinutes, forKey: Keys.refreshMinutes)
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
        if scheduleRefresh { secondsUntilLive = 0 }
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

    private func tick() {
        now = Date()
        if showBattery, Int(now.timeIntervalSince1970) % 30 == 0 {
            battery = BatteryReader.current()
        }
        secondsUntilLive -= 1
        if secondsUntilLive <= 0 {
            secondsUntilLive = liveInterval
            reloadTask?.cancel()
            reloadTask = Task { await performReload(includeLive: liveEnabled, userInitiated: false) }
        }
    }

    private var liveInterval: Int {
        max(60, Int(refreshMinutes * 60))
    }

    private func performReload(includeLive: Bool, userInitiated: Bool) async {
        if userInitiated { isRefreshing = true }
        defer { if userInitiated { isRefreshing = false } }

        let chat: ProviderAccount
        let cursor: ProviderAccount?
        let claude: ProviderAccount?
        async let chatTask = ChatGPTAccountLoader.load(includeLive: true)
        if includeLive {
            async let cursorTask = CursorAccountLoader.load()
            async let claudeTask = ClaudeAccountLoader.load()
            chat = await chatTask
            cursor = await cursorTask
            claude = await claudeTask
        } else {
            chat = await chatTask
            cursor = nil
            claude = nil
        }
        if Task.isCancelled { return }

        var next = accounts
        merge(chat, into: &next)
        if let cursor { merge(cursor, into: &next) }
        if let claude { merge(claude, into: &next) }
        accounts = next
        if !chat.windows.isEmpty { considerAlerts(for: chat) }
        if let cursor, !cursor.windows.isEmpty { considerAlerts(for: cursor) }
        if let claude, !claude.windows.isEmpty { considerAlerts(for: claude) }
        battery = BatteryReader.current()

        if userInitiated {
            secondsUntilLive = liveInterval
        }
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
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }

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
