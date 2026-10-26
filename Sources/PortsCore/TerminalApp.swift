import Foundation

/// Preferred terminal for opening a project folder. Raw values are persisted and must not be renamed.
public enum TerminalApp: String, CaseIterable, Codable, Sendable {
    case terminal, iterm, ghostty, warp

    public var bundleIdentifier: String {
        switch self {
        case .terminal: "com.apple.Terminal"
        case .iterm: "com.googlecode.iterm2"
        case .ghostty: "com.mitchellh.ghostty"
        case .warp: "dev.warp.Warp-Stable"
        }
    }

    /// Product names are never localized.
    public var displayName: String {
        switch self {
        case .terminal: "Terminal"
        case .iterm: "iTerm2"
        case .ghostty: "Ghostty"
        case .warp: "Warp"
        }
    }
}
