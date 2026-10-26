import Foundation
import Testing

@testable import PortsCore

struct PreferencesMigrationTests {
    // Schema before the additive fields, with non-default choices and user-created data.
    private let legacy = """
        {
          "version": 1,
          "preferences": {
            "refreshInterval": 10,
            "showOtherListeners": true,
            "showNotch": true,
            "favoriteProjects": ["/tmp/favorite"],
            "launchConfigurations": [{
              "id": "2714C46E-CC2A-4A8E-BA3E-B561634BDAE7",
              "name": "Frontend", "command": "npm run dev", "directory": "/tmp/project"
            }],
            "agentRules": [{
              "id": "251D6403-D66D-4734-935B-C385E43A32A5",
              "name": "Custom", "executableName": "custom-agent"
            }]
          }
        }
        """

    @Test func firstLaunchDoesNotCreateOrCompletePreferences() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("preferences.json")
        let loaded = try PreferencesRepository(url: url).load()
        #expect(!loaded.hasCompletedOnboarding)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test func legacyDataSurvivesOnboardingCompletionAndReload() throws {
        try withRepository(legacy) { repository in
            var preferences = try repository.load()
            #expect(!preferences.hasCompletedOnboarding)
            let unchanged = try String(contentsOf: repository.url, encoding: .utf8)
            #expect(unchanged == legacy)
            preferences.hasCompletedOnboarding = true
            try repository.save(preferences)
            let restored = try repository.load()
            #expect(restored.hasCompletedOnboarding)
            #expect(restored.refreshInterval == 10)
            #expect(restored.showNotch)
            #expect(restored.showOtherListeners)
            #expect(restored.favoriteProjects == ["/tmp/favorite"])
            let launch = try #require(restored.launchConfigurations.first)
            #expect(launch.name == "Frontend")
            #expect(launch.command == "npm run dev")
            #expect(launch.directory == "/tmp/project")
            #expect(launch.id.uuidString == "2714C46E-CC2A-4A8E-BA3E-B561634BDAE7")
            let rule = try #require(restored.agentRules.first)
            #expect(rule.name == "Custom")
            #expect(rule.executableName == "custom-agent")
            #expect(rule.id.uuidString == "251D6403-D66D-4734-935B-C385E43A32A5")
        }
    }

    @Test(arguments: ["\"yes\"", "1"])
    func invalidCompletionFlagIsNotSilentlyReset(value: String) throws {
        let invalid = legacy.replacingOccurrences(
            of: "\"refreshInterval\": 10,",
            with: "\"hasCompletedOnboarding\": \(value), \"refreshInterval\": 10,")
        try withRepository(invalid) { repository in
            #expect(throws: (any Error).self) { try repository.load() }
            let unchanged = try String(contentsOf: repository.url, encoding: .utf8)
            #expect(unchanged == invalid)
        }
    }

    @Test func additiveMigrationStillRejectsMalformedExistingFields() throws {
        let invalid = legacy.replacingOccurrences(of: "\"showNotch\": true", with: "\"showNotch\": \"true\"")
        try withRepository(invalid) { repository in
            #expect(throws: (any Error).self) { try repository.load() }
            let unchanged = try String(contentsOf: repository.url, encoding: .utf8)
            #expect(unchanged == invalid)
        }
    }

    @Test func legacySchemaGetsDefaultsForNewFields() throws {
        try withRepository(legacy) { repository in
            let loaded = try repository.load()
            #expect(!loaded.groupsServicesByProject)
            #expect(loaded.lastLaunchDirectory == nil)
            #expect(!loaded.checksForUpdatesAutomatically)
            #expect(loaded.lastUpdateCheck == nil)
            #expect(loaded.latestKnownVersion == nil)
            #expect(loaded.dismissedUpdateVersion == nil)
            #expect(loaded.terminalApp == .terminal)
            #expect(loaded.opensWithGlobalShortcut)
            #expect(loaded.detectsAutomatically)
            #expect(loaded.refreshInterval == 10)
        }
    }

    @Test func newFieldsSurviveSaveAndReload() throws {
        try withRepository(legacy) { repository in
            var preferences = try repository.load()
            let checked = Date(timeIntervalSinceReferenceDate: 800_000_000.25)
            preferences.groupsServicesByProject = true
            preferences.lastLaunchDirectory = "/tmp/site"
            preferences.checksForUpdatesAutomatically = true
            preferences.lastUpdateCheck = checked
            preferences.latestKnownVersion = "1.1.0"
            preferences.dismissedUpdateVersion = "1.0.5"
            preferences.terminalApp = .ghostty
            preferences.opensWithGlobalShortcut = false
            preferences.detectsAutomatically = false
            try repository.save(preferences)
            let restored = try repository.load()
            #expect(restored.groupsServicesByProject)
            #expect(restored.lastLaunchDirectory == "/tmp/site")
            #expect(restored.checksForUpdatesAutomatically)
            #expect(restored.lastUpdateCheck == checked)
            #expect(restored.latestKnownVersion == "1.1.0")
            #expect(restored.dismissedUpdateVersion == "1.0.5")
            #expect(restored.terminalApp == .ghostty)
            #expect(!restored.opensWithGlobalShortcut)
            #expect(!restored.detectsAutomatically)
            #expect(restored.favoriteProjects == ["/tmp/favorite"])
            // The on-disk format is a reference-date number, not a formatted string.
            let json = try JSONSerialization.jsonObject(with: Data(contentsOf: repository.url)) as? [String: Any]
            let stored = json?["preferences"] as? [String: Any]
            #expect(stored?["lastUpdateCheck"] as? Double == 800_000_000.25)
            #expect(stored?["terminalApp"] as? String == "ghostty")
        }
    }

    @Test func unknownTerminalFallsBackToTerminal() throws {
        let future = legacy.replacingOccurrences(
            of: "\"refreshInterval\": 10,", with: "\"terminalApp\": \"kitty\", \"refreshInterval\": 10,")
        try withRepository(future) { repository in
            let loaded = try repository.load()
            #expect(loaded.terminalApp == .terminal)
            #expect(loaded.refreshInterval == 10)
            #expect(loaded.showNotch)
        }
    }

    @Test(arguments: [
        "\"terminalApp\": 3", "\"checksForUpdatesAutomatically\": \"yes\"", "\"opensWithGlobalShortcut\": 1",
        "\"lastUpdateCheck\": \"2026-01-01\"", "\"lastLaunchDirectory\": 5", "\"groupsServicesByProject\": \"no\"",
        "\"detectsAutomatically\": \"true\"",
    ])
    func malformedNewFieldsAreRejectedAndFileKept(field: String) throws {
        let invalid = legacy.replacingOccurrences(
            of: "\"refreshInterval\": 10,", with: "\(field), \"refreshInterval\": 10,")
        try withRepository(invalid) { repository in
            #expect(throws: (any Error).self) { try repository.load() }
            let unchanged = try Data(contentsOf: repository.url)
            #expect(unchanged == Data(invalid.utf8))
        }
    }

    @Test func brandMigrationPreservesSettingsAndOriginal() throws {
        try withRepository(legacy) { old in
            let destination = old.url.deletingLastPathComponent().appending(path: "Byte Ports/preferences.json")
            let repository = PreferencesRepository(url: destination, legacyURL: old.url)
            var loaded = try repository.load()
            #expect(loaded.favoriteProjects == ["/tmp/favorite"])
            #expect(!loaded.hasAcknowledgedPublicSharing)
            let original = try String(contentsOf: old.url, encoding: .utf8)
            #expect(original == legacy)
            loaded.refreshInterval = 5
            loaded.hasAcknowledgedPublicSharing = true
            try repository.save(loaded)
            let restored = try repository.load()
            #expect(restored.refreshInterval == 5)
            #expect(restored.hasAcknowledgedPublicSharing)
        }
    }

    @Test func malformedLegacyDataIsNeverMigratedOrOverwritten() throws {
        try withRepository("broken") { old in
            let destination = old.url.deletingLastPathComponent().appending(path: "new/preferences.json")
            #expect(throws: (any Error).self) {
                try PreferencesRepository(url: destination, legacyURL: old.url).load()
            }
            #expect(!FileManager.default.fileExists(atPath: destination.path))
            let original = try String(contentsOf: old.url, encoding: .utf8)
            #expect(original == "broken")
        }
    }

    private func withRepository(_ contents: String, body: (PreferencesRepository) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = PreferencesRepository(url: directory.appendingPathComponent("preferences.json"))
        try Data(contents.utf8).write(to: repository.url)
        try body(repository)
    }
}
