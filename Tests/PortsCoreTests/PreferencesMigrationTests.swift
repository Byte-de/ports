import Foundation
import Testing

@testable import PortsCore

struct PreferencesMigrationTests {
    // Actual 1.0/1.1 schema, with non-default choices and user-created data.
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
