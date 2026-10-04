// Render the actual SwiftUI panel with synthetic accounts, without reading credentials.
// Compile with all ChatGPTGauge Swift files except ChatGPTGaugeApp.swift.
import AppKit
import SwiftUI

@main
struct Preview {
    static func main() {
        MainActor.assumeIsolated {
            let app = NSApplication.shared
            app.setActivationPolicy(.accessory)
            app.appearance = NSAppearance(named: .aqua)
            let output = CommandLine.arguments[1]
            let language = AppLanguage(rawValue: CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "zh") ?? .zh
            let storage = UserDefaults(suiteName: "MacTokenGauge.preview.\(UUID())")!
            storage.set(true, forKey: "onboardingComplete")
            storage.set(false, forKey: "alertsEnabled")
            storage.set(language.rawValue, forKey: "appLanguage")
            storage.set(false, forKey: "claudeEnabled")
            let now = Date()
            let examples = [
                ProviderAccount(id: "chatgpt", name: "ChatGPT", menuTitle: "GPT", plan: "Plus", accountLabel: nil,
                    windows: [UsageWindow(id: "primary", title: "5h", usedPercent: 20, resetAt: now.addingTimeInterval(7200), windowSeconds: 18000),
                              UsageWindow(id: "secondary", title: "7d", usedPercent: 45, resetAt: now.addingTimeInterval(172800), windowSeconds: 604800)],
                    status: L10n.s(.gptExpired, language), capturedAt: now.addingTimeInterval(-600), creditsBalance: nil, note: nil,
                    state: .stale, attemptedAt: now.addingTimeInterval(-60)),
                ProviderAccount(id: "cursor", name: "Cursor", menuTitle: "Cursor", plan: "Pro", accountLabel: nil,
                    windows: [UsageWindow(id: "cursor-total", title: "month", usedPercent: 65, resetAt: now.addingTimeInterval(864000), windowSeconds: 2592000),
                              UsageWindow(id: "cursor-ondemand", title: "spend", amount: Decimal(string: "23.09")!, currency: "USD", resetAt: now.addingTimeInterval(864000), windowSeconds: 2592000)],
                    status: "", capturedAt: now, creditsBalance: nil, note: nil, attemptedAt: now),
                ProviderAccount(id: "claude", name: "Claude", menuTitle: "Claude", plan: nil, accountLabel: nil,
                    windows: [], status: "", capturedAt: nil, creditsBalance: nil, note: nil, state: .paused)
            ]
            let monitor = UsageMonitor(defaults: storage, providerLoader: { id in examples.first { $0.id == id }! })
            monitor.accounts = examples
            let host = NSHostingView(rootView: PopoverView(monitor: monitor).background(Color(nsColor: .windowBackgroundColor)))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 820),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = host
            window.backgroundColor = .windowBackgroundColor
            window.orderFront(nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                monitor.battery = BatteryReading(percent: 68, charging: false)
                host.layoutSubtreeIfNeeded()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    guard let image = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { exit(1) }
                    host.cacheDisplay(in: host.bounds, to: image)
                    try! image.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: output))
                    monitor.stop()
                    window.orderOut(nil)
                    exit(0)
                }
            }
            app.run()
        }
    }
}
