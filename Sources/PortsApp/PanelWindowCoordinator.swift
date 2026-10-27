import AppKit
import PortsCore

/// Shows the one panel on one surface: the expanded notch or the window. Dialogs stay on their owner, so a surface
/// change cannot discard an unfinished form.
@MainActor
final class PanelWindowCoordinator: NSObject {
    static let shared = PanelWindowCoordinator()
    private var presentation = PanelPresentation()
    private weak var model: MonitorModel?
    private weak var mainPanel: MainPanelController?

    override init() {
        super.init()
        NotificationCenter.default.addObserver(
            self, selector: #selector(windowBecameKey), name: NSWindow.didBecomeKeyNotification, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(windowClosed), name: NSWindow.willCloseNotification, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(occlusionChanged), name: NSWindow.didChangeOcclusionStateNotification,
            object: nil)
    }

    func install(model: MonitorModel, mainPanel: MainPanelController) {
        self.model = model
        self.mainPanel = mainPanel
    }

    /// Runs at launch, after onboarding and when the setting changes. An enabled notch takes the panel over from the
    /// window, so it never opens in the middle of the screen; disabling an expanded notch hands it back. Onboarding
    /// always runs in the window, so the notch is not the home meanwhile.
    func configureNotch(model: MonitorModel) {
        self.model = model
        let wasExpanded = presentation.active == .notch
        presentation.configureNotch(
            model.preferences.showNotch && model.onboardingSession == nil, dialogOwner: dialogOwner)
        let movedToNotch = !wasExpanded && presentation.active == .notch
        if movedToNotch { model.presentationSurface = .notch }
        applyVisibility(animated: movedToNotch && PanelMotion.animatesInteraction)
        if wasExpanded && presentation.active == .window { showWindow() }
    }

    /// Shows the panel where it lives: the expanded notch while the notch is enabled, otherwise the window at its
    /// last position.
    func showHome() {
        if presentation.home == .notch { showNotch() } else { showWindow() }
    }

    /// The status item's click. A window behind other windows or on another Space comes forward instead of hiding.
    func toggleHome() {
        let home = presentation.home
        // The policy decides on a copy; showHome and hide then apply the change with its side effects.
        var next = presentation
        guard home == .notch || mainPanel?.isOnScreen == true, next.toggleHome(dialogOwner: dialogOwner),
            next.active == nil
        else { return showHome() }
        hide(home)
    }

    /// Onboarding and launch actions open in the window. Activation can be refused, the window comes forward anyway.
    func showWindow() {
        guard let mainPanel else {
            PortsLog.lifecycle.error("Window requested before the panel was created")
            return
        }
        guard activate(.window) else { return }
        mainPanel.show()
        reportVisibility(mainPanel.window)
    }

    /// The window's close button. The panel stays mounted; the status item shows it again at the same position.
    func closeWindow() { hide(.window) }

    /// The compact notch and the notch's collapse button.
    func toggleNotch() {
        guard let model else { return }
        if model.hasBlockingPanelDialog {
            raiseDialogOwner()
        } else if presentation.active == .notch {
            hide(.notch)
        } else {
            activate(.notch, animated: PanelMotion.animatesInteraction)
        }
    }

    private var dialogOwner: MonitorSurface? {
        guard let model, model.hasBlockingPanelDialog else { return nil }
        return model.presentationSurface
    }

    private func showNotch() {
        if presentation.active == .notch {
            NotchController.shared.raise()
        } else {
            activate(.notch, animated: PanelMotion.animatesInteraction)
        }
    }

    /// The panel stays mounted while hidden, so drafts and the scroll position survive.
    private func hide(_ surface: MonitorSurface) {
        presentation.dismiss(surface)
        applyVisibility(animated: PanelMotion.animatesInteraction)
    }

    @discardableResult private func activate(_ surface: MonitorSurface, animated: Bool = false) -> Bool {
        guard let model else { return true }
        let owner = dialogOwner
        guard presentation.activate(surface, dialogOwner: owner) else {
            raiseDialogOwner()
            return false
        }
        model.presentationSurface = surface
        applyVisibility(animated: animated)
        return true
    }

    /// Hides every surface but the active one; the notch also collapses or expands here.
    private func applyVisibility(animated: Bool = false) {
        guard let model else { return }
        if presentation.active != .window, let mainPanel {
            mainPanel.hide()
            reportVisibility(mainPanel.window)
        }
        NotchController.shared.update(model: model, expanded: presentation.active == .notch, animated: animated)
    }

    private func raiseDialogOwner() {
        guard let owner = dialogOwner else { return }
        presentation.activate(owner, dialogOwner: owner)
        applyVisibility()
        switch owner {
        case .window:
            guard let mainPanel else { return }
            mainPanel.show()
            reportVisibility(mainPanel.window)
        case .notch: NotchController.shared.raise()
        }
    }

    /// Feeds the scan cadence. A window that is hidden, fully covered or on another Space counts as hidden.
    private func reportVisibility(_ window: NSWindow) {
        guard window === mainPanel?.window else { return }
        model?.setSurface(.window, visible: window.isVisible && window.occlusionState.contains(.visible))
    }

    @objc private func windowBecameKey(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window === mainPanel?.window else { return }
        reportVisibility(window)
        activate(.window)
    }

    @objc private func occlusionChanged(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        reportVisibility(window)
    }

    @objc private func windowClosed(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window === mainPanel?.window else { return }
        presentation.dismiss(.window)
        model?.setSurface(.window, visible: false)
    }
}
