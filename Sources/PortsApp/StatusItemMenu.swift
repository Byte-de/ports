import AppKit
import PortsCore

/// MenuBarExtra has no context menu, so a right click or Control-click on the status item is taken before SwiftUI
/// opens the panel, and a small AppKit menu appears instead. Without a Dock icon it is the quickest way to quit.
@MainActor
final class StatusItemMenu: NSObject {
    static let shared = StatusItemMenu()
    private weak var model: MonitorModel?
    private var monitor: Any?

    func install(model: MonitorModel) {
        self.model = model
        guard monitor == nil else { return }
        // Local monitors run on the main thread.
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.rightMouseDown, .leftMouseDown]) { event in
            MainActor.assumeIsolated { StatusItemMenu.shared.handle(event) } ? nil : event
        }
    }

    private func handle(_ event: NSEvent) -> Bool {
        let isContextClick =
            event.type == .rightMouseDown || (event.type == .leftMouseDown && event.modifierFlags.contains(.control))
        // The status item lives in a private AppKit window class; the panel MenuBarExtra opens is an ordinary panel.
        guard isContextClick, let window = event.window, String(describing: type(of: window)) == "NSStatusBarWindow"
        else { return false }
        let button = Self.statusButton(in: window.contentView)
        button?.highlight(true)
        defer { button?.highlight(false) }
        // Screen coordinates: the menu's top-left corner sits under the item, like a status item's own menu.
        menu().popUp(positioning: nil, at: NSPoint(x: window.frame.minX, y: window.frame.minY - 2), in: nil)
        return true
    }

    private static func statusButton(in view: NSView?) -> NSStatusBarButton? {
        guard let view else { return nil }
        if let button = view as? NSStatusBarButton { return button }
        for subview in view.subviews {
            if let button = statusButton(in: subview) { return button }
        }
        return nil
    }

    private func menu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let busy = model.map { $0.onboardingSession != nil || $0.hasPanelDialog } ?? true
        menu.addItem(
            item(String(localized: "Open \(AppInfo.name)", comment: "Status item menu"), #selector(open)))
        menu.addItem(
            item(
                String(localized: "Settings…", comment: "Status item menu"), #selector(openSettings), key: ",",
                enabled: !busy))
        menu.addItem(.separator())
        menu.addItem(
            item(String(localized: "Quit \(AppInfo.name)", comment: "Status item menu"), #selector(quit), key: "q"))
        return menu
    }

    private func item(_ title: String, _ action: Selector, key: String = "", enabled: Bool = true) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        item.isEnabled = enabled
        return item
    }

    @objc private func open() { model?.showMainWindow() }

    @objc private func openSettings() {
        model?.navigate(.settings)
        model?.showMainWindow()
    }

    @objc private func quit() { QuitCoordinator.shared.requestQuit() }
}
