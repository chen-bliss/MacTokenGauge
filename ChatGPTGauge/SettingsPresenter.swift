import AppKit
import SwiftUI

@MainActor
enum SettingsPresenter {
    private static var window: NSWindow?

    static func show(monitor: UsageMonitor) {
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
        window.level = .floating
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        window.center()
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        self.window = window
    }

    static func retitle() {
        window?.title = L10n.s(.settingsWindow)
    }
}
