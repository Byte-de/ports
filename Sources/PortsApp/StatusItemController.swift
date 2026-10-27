import AppKit
import PortsCore
import SwiftUI

/// The hosted label never wins hit testing, so the status bar button receives every click while SwiftUI draws it.
private final class ClickThroughHostingView<Content: View>: NSHostingView<Content> {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// The app's own status item, which MenuBarExtra could not provide: a click toggles the panel at its home, a right
/// click or Control-click shows a small menu. Without a Dock icon that menu is the quickest way to quit. VoiceOver's
/// press runs the click action, so it toggles too.
@MainActor
final class StatusItemController: NSObject {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private weak var model: MonitorModel?

    init(model: MonitorModel) {
        self.model = model
        super.init()
        guard let button = statusItem.button else { return }
        let label = ClickThroughHostingView(
            rootView: MenuBarLabel(
                model: model, resized: { [weak self] width in self?.updateLength(width) },
                described: { [weak button] text in button?.setAccessibilityLabel(text) }))
        label.sizingOptions = .intrinsicContentSize
        label.translatesAutoresizingMaskIntoConstraints = false
        button.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerYAnchor.constraint(equalTo: button.centerYAnchor),
            label.leadingAnchor.constraint(equalTo: button.leadingAnchor),
        ])
        updateLength(label.fittingSize.width)
        button.target = self
        button.action = #selector(clicked)
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }

    /// The screen whose menu bar holds the item.
    var screen: NSScreen? { statusItem.button?.window?.screen }

    /// The button's own cell is empty, so the item's length follows the hosted label's measured width.
    private func updateLength(_ width: CGFloat) {
        guard width > 0 else { return }
        let length = width.rounded(.up)
        if abs(statusItem.length - length) > 0.5 { statusItem.length = length }
    }

    @objc private func clicked() {
        let event = NSApp.currentEvent
        let isContextClick =
            event?.type == .rightMouseUp
            || (event?.type == .leftMouseUp && event?.modifierFlags.contains(.control) == true)
        if isContextClick { showMenu() } else { PanelWindowCoordinator.shared.toggleHome() }
    }

    /// An assigned menu opens on the next click. It is detached again right away, so a click keeps toggling the panel.
    private func showMenu() {
        statusItem.menu = menu()
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
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

    @objc private func open() { PanelWindowCoordinator.shared.showHome() }

    @objc private func openSettings() {
        model?.push(.settings)
        PanelWindowCoordinator.shared.showHome()
    }

    @objc private func quit() { QuitCoordinator.shared.requestQuit() }
}

/// The status item's content: the port glyph, or a globe while a server is shared publicly, and the service count.
/// It reports its width for the item's length and its VoiceOver label for the button that takes the clicks.
struct MenuBarLabel: View {
    let model: MonitorModel
    let resized: (CGFloat) -> Void
    let described: (String) -> Void

    /// A globe while a server is reachable from the internet, so the share stays visible with every panel closed.
    @MainActor private static let sharingGlyph =
        NSImage(
            systemSymbolName: "globe",
            accessibilityDescription: String(
                localized: "\(AppInfo.name) – public share active",
                comment: "VoiceOver description of the menu bar icon while a server is shared publicly"))
        ?? NSImage()

    private var glyph: NSImage { model.isSharingPublicly ? Self.sharingGlyph : DS.portGlyph }
    /// The glyph's description, which is the app's name unless a share is active, and the count.
    private var accessibilityText: String {
        [glyph.accessibilityDescription ?? AppInfo.name, model.counts.total.formatted()].joined(separator: ", ")
    }

    var body: some View {
        HStack(spacing: 4) {
            Image(nsImage: glyph).renderingMode(.template)
            Text(model.counts.total, format: .number).monospacedDigit()
        }
        .font(Font(NSFont.menuBarFont(ofSize: 0)))
        .padding(.horizontal, 4)
        .fixedSize()
        .accessibilityHidden(true)
        .onGeometryChange(for: CGFloat.self, of: \.size.width) { resized($0) }
        .onChange(of: accessibilityText, initial: true) { _, text in described(text) }
    }
}
