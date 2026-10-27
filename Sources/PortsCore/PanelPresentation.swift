/// Window-independent routing policy: there is one panel, shown on at most one surface at a time.
public enum MonitorSurface: CaseIterable, Equatable, Sendable { case window, notch }

public struct PanelPresentation: Sendable {
    /// Nothing is on screen until the app asks for the panel.
    public private(set) var active: MonitorSurface?
    public private(set) var notchEnabled = false

    public init() {}

    /// Where the panel opens when the app is asked to show it: at the top of the screen while the notch is enabled.
    public var home: MonitorSurface { notchEnabled ? .notch : .window }

    /// Enabling the notch moves a panel that is open in the window up to the notch, unless a dialog holds it there.
    public mutating func configureNotch(_ enabled: Bool, dialogOwner: MonitorSurface? = nil) {
        notchEnabled = enabled
        if enabled && active == .window && dialogOwner == nil { active = .notch }
        if !enabled && active == .notch { active = .window }
    }

    /// Showing a surface replaces the other one. An unfinished dialog keeps its owner.
    @discardableResult
    public mutating func activate(_ surface: MonitorSurface, dialogOwner: MonitorSurface? = nil) -> Bool {
        guard dialogOwner == nil || dialogOwner == surface else { return false }
        guard surface != .notch || notchEnabled else { return false }
        active = surface
        return true
    }

    @discardableResult
    public mutating func showHome(dialogOwner: MonitorSurface? = nil) -> Bool {
        activate(home, dialogOwner: dialogOwner)
    }

    /// A click on the status item hides the panel when it is open at home and shows it there otherwise. A dialog is
    /// never hidden: false means that its owner has to come forward instead.
    @discardableResult
    public mutating func toggleHome(dialogOwner: MonitorSurface? = nil) -> Bool {
        guard active != home || dialogOwner != nil else {
            active = nil
            return true
        }
        return showHome(dialogOwner: dialogOwner)
    }

    public mutating func dismiss(_ surface: MonitorSurface) {
        if active == surface { active = nil }
    }
}
