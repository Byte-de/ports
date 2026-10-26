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

    public func validate(fileManager: FileManager = .default) throws {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw MonitorError.launchFailed("Bitte gib der Aktion einen Namen.")
        }
        guard !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            !command.contains("\0")
        else {
            throw MonitorError.launchFailed("Bitte gib einen gültigen Befehl ein.")
        }
        var isDirectory: ObjCBool = false
        guard directory.hasPrefix("/"), fileManager.fileExists(atPath: directory, isDirectory: &isDirectory),
            isDirectory.boolValue
        else {
            throw MonitorError.launchFailed("Wähle einen vorhandenen Projektordner mit absolutem Pfad.")
        }
    }
}

public struct AppPreferences: Codable, Sendable {
    public var refreshInterval: Double = 3
    public var showOtherListeners: Bool = false
    public var showNotch: Bool = false
    public var launchConfigurations: [LaunchConfiguration] = []
    public var agentRules: [AgentRule] = []
    public var favoriteProjects: Set<String> = []
    public var hasCompletedOnboarding: Bool = false
    public var hasAcknowledgedPublicSharing: Bool = false

    public init() {}

    private enum CodingKeys: String, CodingKey {
        case refreshInterval, showOtherListeners, showNotch, launchConfigurations
        case agentRules, favoriteProjects, hasCompletedOnboarding, hasAcknowledgedPublicSharing
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        refreshInterval = try values.decode(Double.self, forKey: .refreshInterval)
        showOtherListeners = try values.decode(Bool.self, forKey: .showOtherListeners)
        showNotch = try values.decode(Bool.self, forKey: .showNotch)
        launchConfigurations = try values.decode([LaunchConfiguration].self, forKey: .launchConfigurations)
        agentRules = try values.decode([AgentRule].self, forKey: .agentRules)
        favoriteProjects = try values.decode(Set<String>.self, forKey: .favoriteProjects)
        // This additive field did not exist in 1.0/1.1. Keep all previous settings
        // and show the introduction once, without relaxing validation of older fields.
        hasCompletedOnboarding = try values.decodeIfPresent(Bool.self, forKey: .hasCompletedOnboarding) ?? false
        hasAcknowledgedPublicSharing =
            try values.decodeIfPresent(Bool.self, forKey: .hasAcknowledgedPublicSharing) ?? false
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
            throw MonitorError.scanFailed("Die Einstellungsdatei stammt aus einer neueren Version.")
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
