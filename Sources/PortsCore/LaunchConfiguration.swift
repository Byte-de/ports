import Foundation

public struct LaunchConfiguration: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var command: String
    public var directory: String

    public init(id: UUID = UUID(), name: String, command: String, directory: String) {
        self.id = id
        self.name = name
        self.command = command
        self.directory = directory
    }

    /// Throws `LaunchError.invalidName`, `.invalidCommand` or `.invalidDirectory`.
    public func validate(fileManager: FileManager = .default) throws {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw LaunchError.invalidName }
        guard !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !command.contains("\0") else {
            throw LaunchError.invalidCommand
        }
        var isDirectory: ObjCBool = false
        guard directory.hasPrefix("/"), fileManager.fileExists(atPath: directory, isDirectory: &isDirectory),
            isDirectory.boolValue
        else { throw LaunchError.invalidDirectory }
    }

    /// Whether another action in `configurations` has `name`. Names compare trimmed and ignore case and character width,
    /// so “Web ” and “ｗｅｂ” would read as the same action in the list.
    public static func isNameTaken(_ name: String, excluding id: UUID?, in configurations: [LaunchConfiguration])
        -> Bool
    {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return configurations.contains { configuration in
            configuration.id != id
                && configuration.name.trimmingCharacters(in: .whitespacesAndNewlines)
                    .compare(name, options: [.caseInsensitive, .widthInsensitive]) == .orderedSame
        }
    }
}

/// Envelope version 1. Fields added after the first schema are optional on disk and fall back to their defaults;
/// present but malformed values still fail, so an unreadable file is preserved instead of overwritten.
/// `favoriteProjects` and `groupsServicesByProject` are unused since the panel dropped project groups and favorites;
/// they stay in the schema so existing files keep decoding and keep their values.
public struct AppPreferences: Codable, Sendable {
    public var refreshInterval: Double = 3
    public var showOtherListeners: Bool = false
    public var showNotch: Bool = false
    public var launchConfigurations: [LaunchConfiguration] = []
    public var agentRules: [AgentRule] = []
    public var favoriteProjects: Set<String> = []
    public var hasCompletedOnboarding: Bool = false
    public var hasAcknowledgedPublicSharing: Bool = false
    public var groupsServicesByProject: Bool = false
    public var lastLaunchDirectory: String?
    public var checksForUpdatesAutomatically: Bool = false
    public var lastUpdateCheck: Date?
    public var latestKnownVersion: String?
    public var dismissedUpdateVersion: String?
    public var terminalApp: TerminalApp = .terminal
    public var opensWithGlobalShortcut: Bool = true
    public var detectsAutomatically: Bool = true

    public init() {}

    private enum CodingKeys: String, CodingKey {
        case refreshInterval, showOtherListeners, showNotch, launchConfigurations
        case agentRules, favoriteProjects, hasCompletedOnboarding, hasAcknowledgedPublicSharing
        case groupsServicesByProject, lastLaunchDirectory, checksForUpdatesAutomatically, lastUpdateCheck
        case latestKnownVersion, dismissedUpdateVersion, terminalApp, opensWithGlobalShortcut, detectsAutomatically
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        refreshInterval = try values.decode(Double.self, forKey: .refreshInterval)
        showOtherListeners = try values.decode(Bool.self, forKey: .showOtherListeners)
        showNotch = try values.decode(Bool.self, forKey: .showNotch)
        launchConfigurations = try values.decode([LaunchConfiguration].self, forKey: .launchConfigurations)
        agentRules = try values.decode([AgentRule].self, forKey: .agentRules)
        favoriteProjects = try values.decode(Set<String>.self, forKey: .favoriteProjects)
        hasCompletedOnboarding = try values.decodeIfPresent(Bool.self, forKey: .hasCompletedOnboarding) ?? false
        hasAcknowledgedPublicSharing =
            try values.decodeIfPresent(Bool.self, forKey: .hasAcknowledgedPublicSharing) ?? false
        groupsServicesByProject = try values.decodeIfPresent(Bool.self, forKey: .groupsServicesByProject) ?? false
        lastLaunchDirectory = try values.decodeIfPresent(String.self, forKey: .lastLaunchDirectory)
        checksForUpdatesAutomatically =
            try values.decodeIfPresent(Bool.self, forKey: .checksForUpdatesAutomatically) ?? false
        lastUpdateCheck = try values.decodeIfPresent(Date.self, forKey: .lastUpdateCheck)
        latestKnownVersion = try values.decodeIfPresent(String.self, forKey: .latestKnownVersion)
        dismissedUpdateVersion = try values.decodeIfPresent(String.self, forKey: .dismissedUpdateVersion)
        // A terminal added by a newer release falls back instead of blocking every setting.
        terminalApp =
            try values.decodeIfPresent(String.self, forKey: .terminalApp).flatMap(TerminalApp.init(rawValue:))
            ?? .terminal
        opensWithGlobalShortcut = try values.decodeIfPresent(Bool.self, forKey: .opensWithGlobalShortcut) ?? true
        detectsAutomatically = try values.decodeIfPresent(Bool.self, forKey: .detectsAutomatically) ?? true
    }
}

/// Versioned, atomic persistence; malformed files surface an error instead of being overwritten.
public struct PreferencesRepository: Sendable {
    private struct Envelope: Codable {
        let version: Int
        let preferences: AppPreferences
    }
    public let url: URL
    public let legacyURL: URL?

    public init(url: URL, legacyURL: URL? = nil) {
        self.url = url
        self.legacyURL = legacyURL
    }

    public func load() throws -> AppPreferences {
        guard FileManager.default.fileExists(atPath: url.path) else {
            guard let legacyURL, FileManager.default.fileExists(atPath: legacyURL.path) else {
                return AppPreferences()
            }
            // Validate before migrating. Keep the original intact, including on failure.
            let preferences = try PreferencesRepository(url: legacyURL).load()
            try save(preferences)
            return preferences
        }
        let envelope = try JSONDecoder().decode(Envelope.self, from: Data(contentsOf: url))
        guard envelope.version == 1 else {
            throw MonitorError.scanFailed(
                String(
                    localized: "The settings file was created by a newer version.",
                    comment: "Error when the settings file has a newer format than this app reads"))
        }
        var preferences = envelope.preferences
        preferences.refreshInterval = min(
            30, max(2, preferences.refreshInterval.isFinite ? preferences.refreshInterval : 3))
        return preferences
    }

    public func save(_ preferences: AppPreferences) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(Envelope(version: 1, preferences: preferences))
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
