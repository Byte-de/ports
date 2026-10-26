import Darwin
import Foundation
import Testing

@testable import PortsCore

struct RuntimeTests {
    @Test func runnerDoesNotInterpretShellSyntax() throws {
        let literal = "hello; $(printf unexpected) 'quoted'"
        let result = try CommandRunner().run(executable: "/usr/bin/printf", arguments: ["%s", literal])
        #expect(result.output == literal)
        #expect(result.exitCode == 0)
    }

    @Test func runnerTimesOutAndReapsChild() {
        #expect(throws: MonitorError.timedOut) {
            try CommandRunner().run(executable: "/bin/sleep", arguments: ["5"], timeout: 0.1)
        }
    }

    @Test func runnerBoundsOutput() {
        #expect(throws: MonitorError.outputLimit) {
            try CommandRunner().run(
                executable: "/usr/bin/printf", arguments: ["%s", String(repeating: "x", count: 1000)], outputLimit: 64)
        }
    }

    @Test func shellEscapingPreservesSpecialCharacters() throws {
        let literal = "folder's name $(printf bad)\nnext line"
        let result = try CommandRunner().run(
            executable: "/bin/zsh", arguments: ["-c", "printf %s " + ShellEscaping.quote(literal)])
        #expect(result.output == literal)
    }

    @Test func nativeInspectorReadsOwnIdentityWithoutEnvironment() throws {
        let own = try #require(NativeProcessInspector().process(pid: getpid()))
        #expect(own.identity.pid == getpid())
        #expect(own.userID == getuid())
        #expect(own.identity.startSeconds > 0)
        #expect(!own.executable.isEmpty)
        #expect(own.arguments.allSatisfy { !$0.hasPrefix("PATH=") })
    }

    @Test func preferencesRoundTripAndValidateVersion() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let repo = PreferencesRepository(url: directory.appendingPathComponent("preferences.json"))
        var prefs = AppPreferences()
        prefs.favoriteProjects = ["/tmp/project"]
        prefs.launchConfigurations = [.init(name: "Web", command: "npm run dev", directory: "/tmp")]
        prefs.agentRules = [.init(name: "Custom", executableName: "custom-agent")]
        try repo.save(prefs)
        let restored = try repo.load()
        #expect(restored.favoriteProjects == prefs.favoriteProjects)
        #expect(restored.launchConfigurations == prefs.launchConfigurations)
        #expect(restored.agentRules == prefs.agentRules)
        let contents = try Data(contentsOf: repo.url)
        let future = String(decoding: contents, as: UTF8.self).replacingOccurrences(
            of: "\"version\" : 1", with: "\"version\" : 2")
        try Data(future.utf8).write(to: repo.url)
        #expect(throws: (any Error).self) { try repo.load() }
        #expect(try String(contentsOf: repo.url, encoding: .utf8) == future)
    }

    @Test func configurationRejectsMissingDirectoryAndEmptyCommand() {
        #expect(throws: (any Error).self) {
            try LaunchConfiguration(name: "Web", command: "npm run dev", directory: "/not/a/real/ports/path")
                .validate()
        }
        #expect(throws: (any Error).self) {
            try LaunchConfiguration(name: "Web", command: " ", directory: "/tmp").validate()
        }
    }

    @Test func managedLaunchCapturesOutputAndNonzeroExit() async throws {
        let manager = LaunchManager()
        let id = try await manager.start(
            .init(
                name: "Test output", command: "printf 'hello stdout'; printf 'hello stderr' >&2; exit 7",
                directory: "/tmp"))
        var record: LaunchRecord?
        for _ in 0..<30 {
            record = await manager.records().first { $0.id == id }
            if record?.state == .failed { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(record?.state == .failed)
        #expect(record?.exitCode == 7)
        let output = await manager.output(for: id)
        #expect(output.contains("hello stdout"))
        #expect(output.contains("hello stderr"))
    }
}
