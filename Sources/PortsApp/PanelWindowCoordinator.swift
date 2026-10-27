import AppKit
import PortsCore
import SwiftUI

/// Coordinates only the three windows registered by our own views. Dialogs
/// stay on their owner, so a surface change cannot discard an unfinished form.
@MainActor
final class PanelWindowCoordinator: NSObject {
    static let shared = PanelWindowCoordinator()
    private var presentation = PanelPresentation()
    private weak var model: MonitorModel?
    private weak var mainWindow: NSWindow?
    private weak var menuWindow: NSWindow?

    override init() {
        super.init()
        NotificationCenter.default.addObserver(
            self, selector: #selector(windowBecameKey), name: NSWindow.didBecomeKeyNotification, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(windowResignedKey), name: NSWindow.didResignKeyNotification, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(windowClosed), name: NSWindow.willCloseNotification, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(occlusionChanged), name: NSWindow.didChangeOcclusionStateNotification,
            object: nil)
    }

    func register(_ window: NSWindow, surface: MonitorSurface, model: MonitorModel) {
        self.model = model
        switch surface {
        case .window: mainWindow = window
        case .menu: menuWindow = window
        case .notch: return
        }
        reportVisibility(window)
        if window.isKeyWindow || (surface == .menu && window.isVisible) { _ = activate(surface) }
    }

    /// Runs at launch, after onboarding and when the setting changes. An enabled notch takes the panel over from the
    /// window, so it never opens in the middle of the screen; disabling an expanded notch hands it back.
    func configureNotch(model: MonitorModel) {
        self.model = model
        let wasExpanded = presentation.active == .notch
        let owner = model.hasBlockingPanelDialog ? model.presentationSurface : nil
        presentation.configureNotch(model.preferences.showNotch, dialogOwner: owner)
        if model.onboardingSession != nil { presentation.activate(.window) }
        let movedToNotch = !wasExpanded && presentation.active == .notch
        if movedToNotch { model.presentationSurface = .notch }
        applyVisibility(animated: movedToNotch && PanelMotion.animatesInteraction)
        if wasExpanded && !model.preferences.showNotch { model.revealWindow?() }
    }

    /// While the notch is the panel's home, showing the app expands it instead of opening the window.
    func revealNotchIfHome() -> Bool {
        guard let model, presentation.home == .notch, model.onboardingSession == nil else { return false }
        if presentation.active == .notch {
            NotchController.shared.raise()
        } else {
            _ = activate(.notch, animated: PanelMotion.animatesInteraction)
        }
        return true
    }

    func prepareMainWindow() -> Bool { activate(.window) }

    /// Activation can be refused (cooperative activation); ordering front regardless keeps the window visible.
    func bringMainWindowForward() {
        guard let window = mainWindow ?? NSApp.windows.first(where: { $0.identifier?.rawValue == "monitor" })
        else { return }
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }

    func menuAppeared(model: MonitorModel) {
        self.model = model
        guard model.onboardingSession == nil else { return }
        _ = activate(.menu)
    }

    func toggleNotch() {
        guard let model else { return }
        if model.hasBlockingPanelDialog {
            raiseDialogOwner()
        } else if presentation.active == .notch {
            presentation.dismiss(.notch)
            applyVisibility(animated: PanelMotion.animatesInteraction)
        } else {
            _ = activate(.notch, animated: PanelMotion.animatesInteraction)
        }
    }

    /// A transient menu popover is not a stable home for a form. Handoff happens
    /// before the dialog flag is set, avoiding both duplicate panels and lost input.
    func dialogSurface(from requested: MonitorSurface) -> MonitorSurface {
        if requested == .menu {
            model?.revealWindow?()
            return presentation.active == .notch ? .notch : .window
        }
        return requested
    }

    func showLaunch(model: MonitorModel) {
        self.model = model
        if presentation.active != .notch { model.revealWindow?() }
        model.presentLaunch(from: presentation.active == .notch ? .notch : .window)
    }

    @discardableResult private func activate(_ surface: MonitorSurface, animated: Bool = false) -> Bool {
        guard let model else { return true }
        if surface == .menu && model.onboardingSession != nil { return false }
        let owner = model.hasBlockingPanelDialog ? model.presentationSurface : nil
        guard presentation.activate(surface, dialogOwner: owner) else {
            if surface == .window && owner != .window { mainWindow?.orderOut(nil) }
            if surface == .menu && owner != .menu { menuWindow?.orderOut(nil) }
            raiseDialogOwner()
            return false
        }
        model.presentationSurface = surface
        applyVisibility(animated: animated)
        return true
    }

    private func applyVisibility(animated: Bool = false) {
        guard let model else { return }
        if presentation.active != .window { mainWindow?.orderOut(nil) }
        if presentation.active != .menu { menuWindow?.orderOut(nil) }
        NotchController.shared.update(model: model, expanded: presentation.active == .notch, animated: animated)
    }

    private func raiseDialogOwner() {
        switch model?.presentationSurface {
        case .window: mainWindow?.makeKeyAndOrderFront(nil)
        case .menu: menuWindow?.makeKeyAndOrderFront(nil)
        case .notch: NotchController.shared.raise()
        case nil: break
        }
    }

    private func surface(of window: NSWindow) -> MonitorSurface? {
        if window === mainWindow { return .window }
        return window === menuWindow ? .menu : nil
    }

    /// Feeds the scan cadence. A window that is minimised, fully covered or on another Space counts as hidden.
    private func reportVisibility(_ window: NSWindow) {
        guard let surface = surface(of: window) else { return }
        // The menu panel is on screen while it is key, even before its occlusion state catches up.
        let visible =
            window.isVisible
            && (window.occlusionState.contains(.visible) || (surface == .menu && window.isKeyWindow))
        model?.setSurface(surface, visible: visible)
    }

    @objc private func windowBecameKey(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        reportVisibility(window)
        if window === mainWindow { _ = activate(.window) } else if window === menuWindow { _ = activate(.menu) }
    }

    /// The transient menu panel closes when it loses key. Reporting that directly keeps the cadence right even if
    /// the panel's occlusion change is never posted.
    @objc private func windowResignedKey(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window === menuWindow else { return }
        model?.setSurface(.menu, visible: false)
    }

    @objc private func occlusionChanged(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        reportVisibility(window)
    }

    @objc private func windowClosed(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, let surface = surface(of: window) else { return }
        presentation.dismiss(surface)
        model?.setSurface(surface, visible: false)
    }
}

struct PanelWindowRegistration: NSViewRepresentable {
    let surface: MonitorSurface
    let model: MonitorModel

    final class RegistrationView: NSView {
        var attached: ((NSWindow) -> Void)?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            Task { @MainActor [weak self] in
                guard let self, let window else { return }
                attached?(window)
            }
        }
    }

    func makeNSView(context: Context) -> RegistrationView {
        let view = RegistrationView()
        view.attached = { window in
            PanelWindowCoordinator.shared.register(window, surface: surface, model: model)
        }
        return view
    }
    func updateNSView(_ view: RegistrationView, context: Context) {}
}
