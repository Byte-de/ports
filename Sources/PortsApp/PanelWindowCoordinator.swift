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
            self, selector: #selector(windowClosed), name: NSWindow.willCloseNotification, object: nil)
    }

    func register(_ window: NSWindow, surface: MonitorSurface, model: MonitorModel) {
        self.model = model
        switch surface {
        case .window: mainWindow = window
        case .menu: menuWindow = window
        case .notch: return
        }
        if window.isKeyWindow || (surface == .menu && window.isVisible) { _ = activate(surface) }
    }

    func configureNotch(model: MonitorModel) {
        self.model = model
        let wasExpanded = presentation.active == .notch
        presentation.configureNotch(model.preferences.showNotch)
        if model.onboardingSession != nil { presentation.activate(.window) }
        applyVisibility()
        if wasExpanded && !model.preferences.showNotch { model.revealWindow?() }
    }

    func prepareMainWindow() -> Bool { activate(.window) }

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
            return .window
        }
        return requested
    }

    func showLaunch(model: MonitorModel) {
        self.model = model
        let surface: MonitorSurface = presentation.active == .notch ? .notch : .window
        if surface == .window { model.revealWindow?() }
        model.presentLaunch(from: surface)
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

    @objc private func windowBecameKey(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        if window === mainWindow { _ = activate(.window) } else if window === menuWindow { _ = activate(.menu) }
    }

    @objc private func windowClosed(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        if window === mainWindow {
            presentation.dismiss(.window)
        } else if window === menuWindow {
            presentation.dismiss(.menu)
        }
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
