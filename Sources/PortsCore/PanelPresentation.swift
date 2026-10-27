/// Window-independent routing policy: only one surface owns the expanded panel.
public enum MonitorSurface: CaseIterable, Equatable, Sendable { case window, menu, notch }

public struct PanelPresentation: Sendable {
    public private(set) var active: MonitorSurface? = .window
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

    @discardableResult
    public mutating func activate(_ surface: MonitorSurface, dialogOwner: MonitorSurface? = nil) -> Bool {
        guard dialogOwner == nil || dialogOwner == surface else { return false }
        guard surface != .notch || notchEnabled else { return false }
        active = surface
        return true
    }

    public mutating func dismiss(_ surface: MonitorSurface) {
        if active == surface { active = nil }
    }
}
