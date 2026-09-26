import AppKit
import Combine
import SwiftUI

@MainActor
final class StatusItemController: NSObject {
    private let monitor: UsageMonitor
    private let iconItem: NSStatusItem
    private let popover = NSPopover()
    private let hosting: PassThroughHostingView<MenuBarLabel>
    private var cancellable: AnyCancellable?
    private var popoverHost: NSHostingController<AnyView>?
    private var hostingConstraints: [NSLayoutConstraint] = []
    private var outsideClickMonitor: Any?
    private var localClickMonitor: Any?
    private var resignObserver: NSObjectProtocol?

    init(monitor: UsageMonitor) {
        self.monitor = monitor
        iconItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        hosting = PassThroughHostingView(rootView: Self.label(for: monitor))
        super.init()

        iconItem.autosaveName = "MacTokenGauge"
        iconItem.behavior = .removalAllowed
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
        if let button = iconItem.button {
            button.image = nil
            button.title = ""
            button.target = self
            button.action = #selector(togglePopover)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            hosting.translatesAutoresizingMaskIntoConstraints = false
            button.addSubview(hosting)
            hostingConstraints = [
                hosting.centerXAnchor.constraint(equalTo: button.centerXAnchor),
                hosting.centerYAnchor.constraint(equalTo: button.centerYAnchor)
            ]
            NSLayoutConstraint.activate(hostingConstraints)
        }
        updateLabel()

        cancellable = monitor.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.updateLabel() }
        }
    }

    private static func label(for monitor: UsageMonitor) -> MenuBarLabel {
        MenuBarLabel(
            accounts: monitor.accounts,
            battery: monitor.battery,
            showBattery: monitor.showBattery,
            style: monitor.menuBarStyle,
            barSlots: monitor.barSlots,
            now: monitor.now,
            textTemplate: monitor.menuTextTemplate,
            batteryMark: monitor.batteryMark
        )
    }

    private func updateLabel() {
        hosting.rootView = Self.label(for: monitor)
        let contentWidth = max(16, hosting.fittingSize.width)
        if abs(iconItem.length - contentWidth) > 0.5 {
            iconItem.length = contentWidth
        }
        if popover.isShown {
            popoverHost?.rootView = AnyView(popoverRoot)
        }
    }

    private var popoverRoot: some View {
        PopoverView(monitor: monitor)
            .environment(\.layoutDirection, monitor.appLanguage.layoutDirection)
    }

    @objc private func togglePopover() {
        guard let button = iconItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
            return
        }
        let host = NSHostingController(rootView: AnyView(popoverRoot))
        popoverHost = host
        popover.contentViewController = host
        NSApp.activate()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        beginOutsideDismiss()
    }

    /// A menu-bar app is usually not the active app, so a transient popover never
    /// hears clicks on the desktop or in other apps. Watch those clicks directly.
    private func beginOutsideDismiss() {
        endOutsideDismiss()
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: NSApp,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.closePopoverFromOutside()
            }
        }
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor in
                self?.closePopoverFromOutside()
            }
        }
        localClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown]) { [weak self] event in
            guard let self else { return event }
            if event.type == .keyDown {
                if event.keyCode == 53 {
                    self.closePopoverFromOutside()
                    return nil
                }
                return event
            }
            if self.clickStaysInsidePopover(event) { return event }
            self.closePopoverFromOutside()
            return event
        }
    }

    private func clickStaysInsidePopover(_ event: NSEvent) -> Bool {
        if event.window === iconItem.button?.window { return true }
        guard let popoverWindow = popover.contentViewController?.view.window else { return false }
        if event.window === popoverWindow { return true }
        let screenPoint: NSPoint
        if let window = event.window {
            screenPoint = window.convertPoint(toScreen: event.locationInWindow)
        } else {
            screenPoint = NSEvent.mouseLocation
        }
        return popoverWindow.frame.contains(screenPoint)
    }

    private func closePopoverFromOutside() {
        guard popover.isShown else { return }
        popover.performClose(nil)
    }

    private func endOutsideDismiss() {
        if let resignObserver {
            NotificationCenter.default.removeObserver(resignObserver)
            self.resignObserver = nil
        }
        if let outsideClickMonitor {
            NSEvent.removeMonitor(outsideClickMonitor)
            self.outsideClickMonitor = nil
        }
        if let localClickMonitor {
            NSEvent.removeMonitor(localClickMonitor)
            self.localClickMonitor = nil
        }
    }
}

extension StatusItemController: NSPopoverDelegate {
    func popoverDidClose(_ notification: Notification) {
        endOutsideDismiss()
    }
}

private final class PassThroughHostingView<Content: View>: NSHostingView<Content> {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
