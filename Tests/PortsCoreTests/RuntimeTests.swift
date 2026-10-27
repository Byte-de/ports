import Darwin
import Foundation
import Testing

@testable import PortsCore

struct RuntimeTests {
    @Test func shellEscapingPreservesSpecialCharacters() throws {
        let literal = "folder's name $(printf bad)\nnext line"
        #expect(try zsh("printf %s " + ShellEscaping.quote(literal)) == literal)
    }

    @Test func nativeInspectorReadsOwnIdentityWithoutEnvironment() throws {
        let own = try #require(NativeProcessInspector().process(pid: getpid()))
        #expect(own.identity.pid == getpid())
        #expect(own.userID == getuid())
        #expect(own.identity.startSeconds > 0)
        #expect(!own.executable.isEmpty)
        #expect(own.arguments.allSatisfy { !$0.hasPrefix("PATH=") })
    }

    @Test func nativeInspectorReadsOwnArgumentsExactly() throws {
        let inspector = NativeProcessInspector()
        var cache = ArgumentCache()
        for _ in 0..<2 {
            let own = try #require(try inspector.processes(reusing: &cache).first { $0.identity.pid == getpid() })
            #expect(own.arguments == CommandLine.arguments)
        }
        #expect(cache.count > 0)
        #expect(inspector.process(pid: getpid())?.arguments == CommandLine.arguments)
    }

    @Test func readsArgumentListsLongerThanScratchBuffer() async throws {
        let long = String(repeating: "a", count: 100_000)
        let expected = ["sleep 5; true", "ports-test", long]
        let shell = Process()
        shell.executableURL = URL(fileURLWithPath: "/bin/sh")
        // The trailing command keeps sh from replacing itself with sleep.
        shell.arguments = ["-c"] + expected
        shell.standardInput = FileHandle.nullDevice
        try shell.run()
        defer { shell.terminate() }
        let inspector = NativeProcessInspector()
        var cache = ArgumentCache()
        var scanned: [String] = []
        // /bin/sh execs the selected shell with the same argv; poll until the process is listed.
        for _ in 0..<20 {
            let records = try inspector.processes(reusing: &cache)
            scanned = records.first { $0.identity.pid == shell.processIdentifier }?.arguments ?? []
            if scanned.suffix(3).elementsEqual(expected) { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(scanned.suffix(3).elementsEqual(expected))
        let fresh = try #require(inspector.process(pid: shell.processIdentifier))
        #expect(fresh.arguments.suffix(3).elementsEqual(expected))
    }

    @Test func identityLookupMatchesFullRecordAndIsNilForMissingPid() throws {
        let inspector = NativeProcessInspector()
        let own = try #require(inspector.process(pid: getpid()))
        #expect(inspector.identity(pid: getpid()) == own.identity)
        // macOS PIDs stay below 100 000.
        #expect(inspector.identity(pid: 999_999) == nil)
        #expect(inspector.identity(pid: 0) == nil)
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
        #expect(throws: LaunchError.invalidDirectory) {
            try LaunchConfiguration(name: "Web", command: "npm run dev", directory: "/not/a/real/ports/path")
                .validate()
        }
        #expect(throws: LaunchError.invalidDirectory) {
            try LaunchConfiguration(name: "Web", command: "npm run dev", directory: "tmp").validate()
        }
        #expect(throws: LaunchError.invalidCommand) {
            try LaunchConfiguration(name: "Web", command: " ", directory: "/tmp").validate()
        }
        #expect(throws: LaunchError.invalidName) {
            try LaunchConfiguration(name: " ", command: "npm run dev", directory: "/tmp").validate()
        }
    }

    @Test func stopTerminatesBackgroundChildren() async throws {
        let manager = LaunchManager(environment: FixedShellEnvironment(.fallback(.noOutput)))
        let inspector = NativeProcessInspector()
        let id = try await manager.start(
            .init(name: "Background children", command: "sleep 30 & sleep 30 & wait", directory: "/tmp"))
        let launched = await manager.records().first { $0.id == id }
        let root = try #require(launched?.identity)
        var children: [ProcessRecord] = []
        for _ in 0..<100 {
            children = inspector.childPIDs(of: root.pid).compactMap(inspector.process(pid:)).filter {
                $0.name == "sleep"
            }
            if children.count == 2 { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        defer {
            for child in children where inspector.identity(pid: child.identity.pid) == child.identity {
                kill(child.identity.pid, SIGKILL)
            }
        }
        #expect(children.count == 2)
        #expect(try await manager.stop(id) == .stopped)
        for child in children { #expect(inspector.identity(pid: child.identity.pid) != child.identity) }
        #expect(await manager.status(for: id) == .stopped)
    }

    @Test func detachedDaemonIsNeitherSignalledNorKeepsJobRunning() async throws {
        let manager = LaunchManager(environment: FixedShellEnvironment(.fallback(.noOutput)))
        let inspector = NativeProcessInspector()
        // The daemon prints its PID once it has its own session. Its parent waits a second, so the job tracks the
        // daemon before launchd adopts it.
        let command = #"perl -MPOSIX -e 'if (fork) { sleep 1; exit } POSIX::setsid(); $| = 1; print "$$\n"; sleep 30'"#
        let id = try await manager.start(.init(name: "Detached daemon", command: command, directory: "/tmp"))
        var state: LaunchState?
        var daemon: ProcessRecord?
        for _ in 0..<100 {
            state = await manager.records().first { $0.id == id }?.state
            let printed = await manager.output(for: id).split(separator: "\n").compactMap { Int32($0) }.last
            daemon = printed.flatMap(inspector.process(pid:))
            if state == .finished, daemon != nil { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        let detached = try #require(daemon)
        defer {
            if inspector.identity(pid: detached.identity.pid) == detached.identity {
                kill(detached.identity.pid, SIGKILL)
            }
        }
        #expect(detached.parentPID == 1)
        #expect(state == .finished)
        try await manager.stop(id)
        #expect(inspector.identity(pid: detached.identity.pid) == detached.identity)
    }

    /// Standard output of `/bin/zsh -c command`; the commands here are short and exit on their own.
    private func zsh(_ command: String) throws -> String {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-c", command]
        process.standardOutput = pipe
        process.standardInput = FileHandle.nullDevice
        try process.run()
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: output, as: UTF8.self)
    }
}
