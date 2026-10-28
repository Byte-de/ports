import PortsCore

/// The introduction's draft: where the panel opens, plus the two opt-ins. On a first run neither opt-in is on, so
/// finishing without touching a switch asks GitHub nothing and registers no login item. A repeated introduction shows
/// what is on, so finishing it never undoes an earlier choice.
public struct OnboardingChoices: Equatable, Sendable {
    public var showNotch: Bool
    public var launchAtLogin: Bool
    public var checksForUpdatesAutomatically: Bool

    /// `opensAtLogin` is the login item's live state: System Settings owns it, so preferences never store it.
    public init(preferences: AppPreferences, opensAtLogin: Bool) {
        showNotch = preferences.showNotch
        launchAtLogin = opensAtLogin
        checksForUpdatesAutomatically = preferences.checksForUpdatesAutomatically
    }

    /// Only what the introduction offers; every other preference stays as it is.
    public func apply(to preferences: inout AppPreferences) {
        preferences.showNotch = showNotch
        preferences.checksForUpdatesAutomatically = checksForUpdatesAutomatically
    }

    /// The login item state to request, or nil while the system already matches the choice.
    public func loginItemChange(currentlyEnabled: Bool) -> Bool? {
        launchAtLogin == currentlyEnabled ? nil : launchAtLogin
    }
}
