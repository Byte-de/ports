import Foundation
import PortsCore

/// The panel's roots, in the order of the bottom bar.
public enum PanelTab: Int, CaseIterable, Sendable {
    case servers, agents, actions

    /// ⌘1, ⌘2 and ⌘3 follow the bottom bar from left to right. The panel's shortcuts and the tab tooltips read it.
    public var keyEquivalent: Character {
        switch self {
        case .servers: "1"
        case .agents: "2"
        case .actions: "3"
        }
    }

    /// The services a tab lists; Actions lists launch slots instead.
    public var serviceFilter: ServiceFilter? {
        switch self {
        case .servers: .servers
        case .agents: .agents
        case .actions: nil
        }
    }
}

/// A page pushed over a tab: the header's clock and gear, a row's details or an action's output.
public enum PanelDestination: Hashable, Sendable {
    case settings, activity
    case details(ProcessIdentity)
    case output(UUID)
}

/// Where the panel is. Tabs are roots. Pushed pages remember their origin, so back returns to the tab or page they
/// were opened from, and the tab's list stays mounted underneath with its scroll position. The bottom bar keeps the
/// origin tab highlighted while a page is pushed.
public struct PanelNavigation: Equatable, Sendable {
    public private(set) var tab: PanelTab
    public private(set) var stack: [PanelDestination] = []

    public init(tab: PanelTab = .servers) {
        self.tab = tab
    }

    public var top: PanelDestination? { stack.last }
    public var isAtRoot: Bool { stack.isEmpty }

    /// Always shows the tab's root, so selecting the current tab again pops to it.
    public mutating func select(_ tab: PanelTab) {
        self.tab = tab
        stack.removeAll()
    }

    /// A page that is already open comes back to the top by closing what was pushed over it, never as a second copy.
    public mutating func push(_ destination: PanelDestination) {
        if let index = stack.firstIndex(of: destination) {
            stack.removeSubrange((index + 1)...)
        } else {
            stack.append(destination)
        }
    }

    /// Back. Does nothing on a root.
    public mutating func pop() {
        _ = stack.popLast()
    }

    /// Swaps the page on top, as when a restarted action brings a new output. Does nothing on a root, so it never
    /// reopens a page the user has left.
    public mutating func replaceTop(with destination: PanelDestination) {
        guard !stack.isEmpty else { return }
        stack.removeLast()
        push(destination)
    }
}
