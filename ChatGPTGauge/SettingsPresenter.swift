import AppKit
import SwiftUI

@MainActor
final class SettingsPresenter: NSObject, NSWindowDelegate {
    static let shared = SettingsPresenter()

    private var window: NSWindow?
    private var monitor: UsageMonitor?

    static func show(monitor: UsageMonitor) {
        shared.present(monitor)
    }

    static func close() {
        guard let window = shared.window, window.isVisible else { return }
        window.performClose(nil)
    }

    static func retitle() {
        shared.window?.title = L10n.s(.settingsWindow)
        if let delegate = NSApp.delegate as? AppDelegate {
            AppMenu.install(target: delegate)
        }
    }

    private func present(_ monitor: UsageMonitor) {
        self.monitor = monitor
        NSApp.setActivationPolicy(.accessory)
        NSApp.activate(ignoringOtherApps: true)
        if let window {
            window.makeKeyAndOrderFront(nil)
            window.orderFrontRegardless()
            return
        }

        let host = NSHostingController(rootView: SettingsView(monitor: monitor))
        let window = NSWindow(contentViewController: host)
        window.title = L10n.s(.settingsWindow)
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.setContentSize(NSSize(width: 560, height: 680))
        window.minSize = NSSize(width: 520, height: 460)
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.level = .floating
        window.hidesOnDeactivate = false
        window.delegate = self
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        window.center()
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        self.window = window
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        DispatchQueue.main.async { [weak self] in
            self?.discard(sender)
        }
        return false
    }

    private func discard(_ sender: NSWindow) {
        guard window === sender else { return }
        sender.delegate = nil
        sender.contentViewController = nil
        window = nil
        monitor = nil
        sender.close()
    }
}
