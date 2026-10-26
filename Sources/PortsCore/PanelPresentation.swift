/// Window-independent routing policy: only one surface owns the expanded panel.
public enum MonitorSurface: CaseIterable, Equatable, Sendable { case window, menu, notch }

public struct PanelPresentation: Sendable {
    public private(set) var active: MonitorSurface? = .window
    public private(set) var notchEnabled = false

    public init() {}

    public mutating func configureNotch(_ enabled: Bool) {
        notchEnabled = enabled
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
