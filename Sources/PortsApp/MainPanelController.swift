import AppKit
import SwiftUI

/// Takes key and main status, so search, forms and keyboard shortcuts work in the panel.
@MainActor
private final class MainPanelWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// The window surface. The window draws no frame, title bar or shadow of its own, so the panel's squircle PanelGlass
/// is the only visible shape in light and dark mode. It sits at the normal level and keeps its last position, also
/// across launches.
@MainActor
final class MainPanelController: NSObject {
    private static let autosaveName = "BytePortsPanel"
    let window: NSWindow
    private let anchorScreen: () -> NSScreen?
    private var isPlaced: Bool

    /// `anchorScreen` is the screen that holds the status item, where the window first appears.
    init(model: MonitorModel, anchorScreen: @escaping () -> NSScreen?) {
        // Never miniaturizable: no Dock to restore a minimized window from.
        let window = MainPanelWindow(
            contentRect: NSRect(x: 0, y: 0, width: 504, height: 362),
            styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        window.title = AppInfo.name
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            window.standardWindowButton(button)?.isHidden = true
        }
        // Like the notch, the window matches the panel's deliberately dark surfaces instead of the system appearance.
        window.appearance = NSAppearance(named: .darkAqua)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.tabbingMode = .disallowed
        window.level = .normal
        window.collectionBehavior = [.moveToActiveSpace]
        let hosting = NSHostingView(rootView: MonitorWindow(model: model))
        // The panel has a fixed size, which becomes the window's minimum and maximum: the window follows its height.
        hosting.sizingOptions = [.minSize, .maxSize]
        window.contentView = hosting
        // The hidden window still resizes to its content, which would autosave an unplaced frame, so autosave starts
        // only once the frame is placed.
        isPlaced = window.setFrameUsingName(Self.autosaveName)
        if isPlaced { window.setFrameAutosaveName(Self.autosaveName) }
        self.window = window
        self.anchorScreen = anchorScreen
        super.init()
    }

    /// Visible at least in part on the current Space.
    var isOnScreen: Bool { window.isVisible && window.occlusionState.contains(.visible) }

    func show() {
        if !isPlaced { placeOnAnchorScreen() }
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        // Activation can be refused (cooperative activation); ordering front regardless keeps the window visible.
        window.orderFrontRegardless()
    }

    func hide() { window.orderOut(nil) }

    private func placeOnAnchorScreen() {
        guard let screen = anchorScreen() ?? NSScreen.main else { return }
        // The hosting view sizes the window through its content size limits (its fittingSize stays zero), so let it
        // apply them before measuring.
        window.updateConstraintsIfNeeded()
        let size = window.frame.size
        let area = screen.visibleFrame
        window.setFrame(
            NSRect(
                x: area.midX - size.width / 2, y: area.midY - size.height / 2, width: size.width, height: size.height),
            display: false)
        // Saved right away, so a window that is never moved also reopens here.
        window.setFrameAutosaveName(Self.autosaveName)
        window.saveFrame(usingName: Self.autosaveName)
        isPlaced = true
    }
}
