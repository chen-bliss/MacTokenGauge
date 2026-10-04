import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, ApplicationMenuRetitling {
    let monitor = UsageMonitor()
    private var status: StatusItemController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        AppMenu.install(target: self)
        status = StatusItemController(monitor: monitor)
        monitor.start()
    }

    func applicationWillTerminate(_ notification: Notification) { monitor.stop() }

    @objc func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        false
    }

    @objc func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    @objc func applicationShouldRestoreSecureApplicationState(_ app: NSApplication) -> Bool {
        false
    }

    @objc func application(_ application: NSApplication, shouldSaveApplicationState coder: NSCoder) -> Bool {
        false
    }

    @objc func application(_ application: NSApplication, shouldRestoreApplicationState coder: NSCoder) -> Bool {
        false
    }

    func retitleMenu() { AppMenu.install(target: self) }

    @objc func openSettings(_ sender: Any?) {
        SettingsPresenter.show(monitor: monitor)
    }

    @objc func closeSettingsWindow(_ sender: Any?) {
        SettingsPresenter.close()
    }
}

enum AppMenu {
    @MainActor
    static func install(target: AppDelegate) {
        let appName = L10n.s(.settingsWindow)
        let main = NSMenu()
        let appItem = NSMenuItem()
        appItem.title = appName
        main.addItem(appItem)

        let appMenu = NSMenu(title: appName)
        let settings = NSMenuItem(
            title: L10n.s(.settings),
            action: #selector(AppDelegate.openSettings(_:)),
            keyEquivalent: ","
        )
        settings.target = target
        appMenu.addItem(settings)
        let close = NSMenuItem(
            title: L10n.s(.closeWindow),
            action: #selector(AppDelegate.closeSettingsWindow(_:)),
            keyEquivalent: "q"
        )
        close.target = target
        appMenu.addItem(close)
        let closeWithW = NSMenuItem(
            title: L10n.s(.closeWindow),
            action: #selector(AppDelegate.closeSettingsWindow(_:)),
            keyEquivalent: "w"
        )
        closeWithW.target = target
        closeWithW.isHidden = true
        appMenu.addItem(closeWithW)
        appMenu.addItem(.separator())
        appMenu.addItem(NSMenuItem(
            title: L10n.s(.quit),
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: ""
        ))
        appItem.submenu = appMenu
        NSApp.mainMenu = main
    }
}

@main
enum ChatGPTGaugeMain {
    static func main() {
        MainActor.assumeIsolated {
            let app = NSApplication.shared
            app.setActivationPolicy(.accessory)
            let delegate = AppDelegate()
            app.delegate = delegate
            withExtendedLifetime(delegate) {
                app.run()
            }
        }
    }
}
