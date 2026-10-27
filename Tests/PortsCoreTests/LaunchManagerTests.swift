import Darwin
import Foundation
import Synchronization
import Testing

@testable import PortsCore

/// Runs commands with the login environment, as when the shell environment couldn't be read, without running the
/// user's shell.
private func hermeticManager() -> LaunchManager {
    LaunchManager(environment: FixedShellEnvironment(.fallback(.noOutput)))
}

/// Counts resolutions; its fingerprint changes on request.
private final class CountingShellEnvironment: ShellEnvironmentProviding {
    private let state = Mutex((fingerprint: "first", resolutions: 0))
    var resolutions: Int { state.withLock { $0.resolutions } }
    func changeFingerprint() { state.withLock { $0.fingerprint += "+" } }
    func fingerprint() -> String { state.withLock { $0.fingerprint } }
    func resolve(base: [String: String]) async -> ShellEnvironment {
        state.withLock { $0.resolutions += 1 }
        // Long enough for a second caller to arrive while this resolution runs.
        try? await Task.sleep(for: .milliseconds(200))
        return ShellEnvironment(
            variables: ShellEnvironment.merge(base: base, resolved: [:]), source: .interactive(shell: "/bin/zsh"))
    }
}

struct LaunchManagerTests {
    @Test func managedLaunchCapturesOutputAndNonzeroExit() async throws {
        let manager = hermeticManager()
        let id = try await manager.start(
            .init(
                name: "Test output", command: "printf 'hello stdout'; printf 'hello stderr' >&2; exit 7",
                directory: "/tmp"))
        let record = try await settled(id, in: manager)
        #expect(record.state == .failed)
        #expect(record.exitCode == 7)
        try await waitForOutput("hello stdout", of: id, in: manager)
        try await waitForOutput("hello stderr", of: id, in: manager)
    }

    @Test func restartReusesSlotAndKeepsLog() async throws {
        let manager = hermeticManager()
        let configuration = LaunchConfiguration(
            name: "Restart", command: "printf 'first run\\n'; exec sleep 30", directory: "/tmp")
        let id = try await manager.start(configuration)
        #expect(id == configuration.id)
        try await waitForOutput("first run", of: id, in: manager)
        try await waitForRoot("sleep", of: id, in: manager)
        let first = try #require(await manager.records().first)
        var edited = configuration
        edited.command = "printf 'second run\\n'; exec sleep 30"
        await #expect(throws: LaunchError.unknownJob) {
            try await manager.restart(id, using: LaunchConfiguration(name: "Other", command: "true", directory: "/tmp"))
        }
        #expect(try await manager.restart(id, using: edited) == .stopped)
        try await waitForOutput("second run", of: id, in: manager)
        try await waitForRoot("sleep", of: id, in: manager)
        let records = await manager.records()
        #expect(records.count == 1)
        let record = try #require(records.first)
        #expect(record.id == id)
        #expect(record.runID != first.runID)
        #expect(record.runCount == 2)
        #expect(record.createdAt == first.createdAt)
        #expect(record.startedAt > first.startedAt)
        #expect(record.configuration.command == edited.command)
        #expect(record.state == .running)
        #expect(record.identity != first.identity)
        let runs = await manager.output(for: id).components(separatedBy: "──── Restarted · ")
        #expect(runs.count == 2)
        #expect(runs.first?.contains("first run") == true)
        #expect(runs.last?.contains("second run") == true)
        try await manager.stop(id)
    }

    @Test func startAgainAfterExitReusesSlot() async throws {
        let manager = hermeticManager()
        let configuration = LaunchConfiguration(name: "Again", command: "printf 'pass\\n'", directory: "/tmp")
        let id = try await manager.start(configuration)
        let first = try await settled(id, in: manager)
        #expect(first.state == .finished)
        // A start detaches the previous run's pipe, so its output must have arrived.
        try await waitForOutput("pass\n", of: id, in: manager)
        #expect(try await manager.start(configuration) == id)
        let second = try await settled(id, in: manager)
        try await waitForOutput("pass\n", count: 2, of: id, in: manager)
        #expect(await manager.records().count == 1)
        #expect(second.runCount == 2)
        #expect(second.runID != first.runID)
        #expect(second.createdAt == first.createdAt)
        #expect(second.state == .finished)
        let runs = await manager.output(for: id).components(separatedBy: "──── Started again · ")
        #expect(runs.count == 2)
        #expect(runs.allSatisfy { $0.contains("pass\n") })
    }

    @Test func startRejectsActiveConfiguration() async throws {
        let manager = hermeticManager()
        let configuration = LaunchConfiguration(name: "Active", command: "exec sleep 30", directory: "/tmp")
        let id = try await manager.start(configuration)
        try await waitForRoot("sleep", of: id, in: manager)
        await #expect(throws: LaunchError.alreadyRunning("Active")) { try await manager.start(configuration) }
        #expect(await manager.status(for: id) == .running)
        #expect(await manager.records().map(\.runCount) == [1])
        try await manager.stop(id)
    }

    @Test func oneOffConfigurationsGetSeparateSlots() async throws {
        let manager = hermeticManager()
        let older = try await manager.start(.init(name: "One-off", command: "true", directory: "/tmp"))
        let newer = try await manager.start(.init(name: "One-off", command: "true", directory: "/tmp"))
        #expect(older != newer)
        _ = try await settled(older, in: manager)
        _ = try await settled(newer, in: manager)
        let records = await manager.records()
        #expect(records.map(\.id) == [newer, older])
        #expect(records.allSatisfy { $0.runCount == 1 })
    }

    @Test func removeRefusesActiveAndRemovesFinished() async throws {
        let manager = hermeticManager()
        let id = try await manager.start(
            .init(name: "Removable", command: "printf 'kept\\n'; exec sleep 30", directory: "/tmp"))
        #expect(await !manager.remove(id))
        try await waitForRoot("sleep", of: id, in: manager)
        #expect(try await manager.stop(id) == .stopped)
        #expect(try await settled(id, in: manager).state == .stopped)
        #expect(await manager.remove(id))
        #expect(await manager.records().isEmpty)
        #expect(await manager.status(for: id) == nil)
        #expect(await manager.output(for: id).isEmpty)
        #expect(await !manager.remove(id))
        await #expect(throws: LaunchError.unknownJob) { try await manager.restart(id) }
    }

    @Test func removeFinishedKeepsRunning() async throws {
        let manager = hermeticManager()
        let running = try await manager.start(.init(name: "Running", command: "exec sleep 30", directory: "/tmp"))
        let finished = try await manager.start(.init(name: "Finished", command: "exit 1", directory: "/tmp"))
        _ = try await settled(finished, in: manager)
        #expect(await manager.removeFinished() == [finished])
        #expect(await manager.records().map(\.id) == [running])
        try await waitForRoot("sleep", of: running, in: manager)
        try await manager.stop(running)
    }

    @Test func changesYieldsOnExit() async throws {
        let manager = hermeticManager()
        let id = try await manager.start(.init(name: "Exits", command: "exit 3", directory: "/tmp"))
        let changed = await withTaskGroup(of: UUID?.self) { group in
            group.addTask {
                for await changed in manager.changes where changed == id { return changed }
                return nil
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(2))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
        #expect(changed == id)
        #expect(try await settled(id, in: manager).state == .failed)
    }

    @Test func detachedDaemonNeitherBlocksNorJoinsRestart() async throws {
        let manager = hermeticManager()
        let inspector = NativeProcessInspector()
        // As in RuntimeTests, the daemon prints its PID once it has its own session and its parent waits a second, so
        // the run tracks the daemon before launchd adopts it. The daemon then keeps writing to its inherited pipe.
        let configuration = LaunchConfiguration(
            name: "Detached daemon",
            command:
                #"perl -MPOSIX -e 'if (fork) { sleep 1; exit } POSIX::setsid(); $| = 1; print "$$\n"; for (1 .. 300) { select(undef, undef, undef, 0.1); print "tick\n" }'"#,
            directory: "/tmp")
        let id = try await manager.start(configuration)
        let (firstState, first) = try await detachedDaemon(of: id, in: manager)
        defer { killDaemon(first) }
        #expect(first.parentPID == 1)
        #expect(firstState == .finished)
        #expect(await manager.status(for: id) == .finished)
        // The daemon is not part of the run, so the configuration starts again, and the new run tracks its own daemon.
        #expect(try await manager.start(configuration) == id)
        let (secondState, second) = try await detachedDaemon(of: id, in: manager)
        defer { killDaemon(second) }
        #expect(second.parentPID == 1)
        #expect(secondState == .finished)
        var quiet = configuration
        quiet.command = "printf 'quiet\\n'"
        #expect(try await manager.restart(id, using: quiet) == .stopped)
        let record = try await settled(id, in: manager)
        #expect(record.state == .finished)
        #expect(record.runCount == 3)
        // Both daemons kept writing to the pipes of runs that were replaced; neither got a signal or SIGPIPE.
        try await Task.sleep(for: .milliseconds(300))
        for daemon in [first, second] {
            #expect(inspector.identity(pid: daemon.identity.pid) == daemon.identity)
        }
    }

    @Test func gracefulTreeStops() async throws {
        let manager = hermeticManager()
        let inspector = NativeProcessInspector()
        let id = try await manager.start(
            .init(name: "Tree", command: "/bin/sh -c 'sleep 30 & wait' & sleep 30 & wait", directory: "/tmp"))
        let root = try #require(await manager.records().first?.identity)
        var tree: [ProcessRecord] = []
        for _ in 0..<100 {
            tree = descendants(of: root.pid)
            if tree.count(where: { $0.name == "sleep" }) == 2 { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        defer { killLeftovers(tree) }
        #expect(tree.count { $0.name == "sleep" } == 2)
        #expect(try await manager.stop(id) == .stopped)
        // The outcome waits until Process has reaped the root, so the state is final right away.
        #expect(await manager.status(for: id) == .stopped)
        #expect(inspector.identity(pid: root.pid) != root)
        for process in tree { #expect(inspector.identity(pid: process.identity.pid) != process.identity) }
    }

    @Test func termIgnoringTreeNeedsExplicitForce() async throws {
        let manager = hermeticManager()
        let id = try await manager.start(
            .init(name: "Ignores TERM", command: "trap '' TERM; exec sleep 30", directory: "/tmp"))
        try await waitForRoot("sleep", of: id, in: manager)
        let record = try #require(await manager.records().first)
        async let outcome = manager.stop(id, grace: .milliseconds(500))
        var sawStopping = false
        for _ in 0..<20 where !sawStopping {
            sawStopping = await manager.status(for: id) == .stopping
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(sawStopping)
        #expect(try await outcome == .stillRunning)
        #expect(await manager.status(for: id) == .unresponsive)
        #expect(NativeProcessInspector().identity(pid: record.identity?.pid ?? 0) == record.identity)
        #expect(try await manager.forceStop(id, run: record.runID) == .stopped)
        let stopped = try #require(await manager.records().first)
        #expect(stopped.state == .stopped)
        #expect(stopped.exitCode == SIGKILL)
    }

    @Test func waitForExitDoesNotResendTerm() async throws {
        let manager = hermeticManager()
        let id = try await manager.start(
            .init(
                name: "Counts TERM",
                command:
                    #"exec perl -e '$| = 1; $SIG{TERM} = sub { print "term\n" }; print "ready\n"; sleep 1 while 1'"#,
                directory: "/tmp"))
        try await waitForOutput("ready", of: id, in: manager)
        #expect(try await manager.stop(id, grace: .milliseconds(300)) == .stillRunning)
        #expect(try await manager.waitForExit(id, grace: .milliseconds(300)) == .stillRunning)
        #expect(await manager.waitForAll([id], grace: .milliseconds(300)) == [id])
        #expect(await manager.status(for: id) == .unresponsive)
        #expect(await manager.output(for: id).components(separatedBy: "term\n").count == 2)
        let run = try #require(await manager.records().first?.runID)
        #expect(try await manager.forceStop(id, run: run) == .stopped)
    }

    @Test func forceStopRejectsStaleRun() async throws {
        let manager = hermeticManager()
        let id = try await manager.start(.init(name: "Stale", command: "exec sleep 30", directory: "/tmp"))
        try await waitForRoot("sleep", of: id, in: manager)
        let first = try #require(await manager.records().first)
        #expect(try await manager.restart(id) == .stopped)
        try await waitForRoot("sleep", of: id, in: manager)
        await #expect(throws: LaunchError.unknownJob) { try await manager.forceStop(id, run: first.runID) }
        await #expect(throws: LaunchError.unknownJob) { try await manager.forceStop(UUID(), run: first.runID) }
        let current = try #require(await manager.records().first)
        #expect(current.state == .running)
        #expect(try await manager.forceStop(id, run: current.runID) == .stopped)
    }

    @Test func forceStopLeavesDetachedDaemonAlone() async throws {
        let manager = hermeticManager()
        let inspector = NativeProcessInspector()
        // The daemon's parent waits a second, so polling records() tracks the daemon before launchd adopts it.
        let id = try await manager.start(
            .init(
                name: "Daemon then sleep",
                command:
                    #"perl -MPOSIX -e 'if (fork) { sleep 1; exit } POSIX::setsid(); $| = 1; print "$$\n"; sleep 30'; exec sleep 30"#,
                directory: "/tmp"))
        try await waitForRoot("sleep", of: id, in: manager)
        let printed = await manager.output(for: id).split(separator: "\n").compactMap { Int32($0) }.last
        let daemon = try #require(printed.flatMap(inspector.process(pid:)))
        defer { killDaemon(daemon) }
        #expect(daemon.parentPID == 1)
        let run = try #require(await manager.records().first?.runID)
        #expect(try await manager.forceStop(id, run: run) == .stopped)
        #expect(inspector.identity(pid: daemon.identity.pid) == daemon.identity)
    }

    @Test func restartReturnsStillRunningWithoutStarting() async throws {
        let manager = hermeticManager()
        let id = try await manager.start(
            .init(name: "Ignores TERM", command: "trap '' TERM; exec sleep 30", directory: "/tmp"))
        try await waitForRoot("sleep", of: id, in: manager)
        let before = try #require(await manager.records().first)
        #expect(try await manager.restart(id, grace: .milliseconds(300)) == .stillRunning)
        let after = try #require(await manager.records().first)
        #expect(after.runID == before.runID)
        #expect(after.runCount == 1)
        #expect(after.identity == before.identity)
        #expect(after.state == .unresponsive)
        #expect(!(await manager.output(for: id).contains("Restarted")))
        #expect(try await manager.forceStop(id, run: before.runID) == .stopped)
    }

    @Test func stopAllStopsInParallel() async throws {
        let manager = hermeticManager()
        // Each job takes half a second to exit after SIGTERM; one after another, three would take 1.5 s.
        var ids: [UUID] = []
        for index in 1...3 {
            ids.append(
                try await manager.start(
                    .init(
                        name: "Slow exit \(index)",
                        command:
                            #"exec perl -e '$| = 1; $SIG{TERM} = sub { select(undef, undef, undef, 0.5); exit 0 }; print "ready\n"; sleep 1 while 1'"#,
                        directory: "/tmp")))
        }
        for id in ids { try await waitForOutput("ready", of: id, in: manager) }
        let clock = ContinuousClock()
        let started = clock.now
        let remaining = await manager.stopAll(grace: .seconds(5))
        let elapsed = started.duration(to: clock.now)
        #expect(remaining.isEmpty)
        #expect(elapsed < .milliseconds(1200))
        for id in ids { #expect(await manager.status(for: id) == .stopped) }
    }

    @Test func startRejectedAfterStopAllUntilResumed() async throws {
        let manager = hermeticManager()
        let configuration = LaunchConfiguration(name: "Quit", command: "exec sleep 30", directory: "/tmp")
        let id = try await manager.start(configuration)
        try await waitForRoot("sleep", of: id, in: manager)
        #expect(await manager.stopAll(grace: .seconds(5)).isEmpty)
        #expect(await manager.status(for: id) == .stopped)
        await #expect(throws: LaunchError.shuttingDown) { try await manager.start(configuration) }
        await #expect(throws: LaunchError.shuttingDown) { try await manager.restart(id) }
        await manager.resumeAfterCancelledQuit()
        #expect(try await manager.start(configuration) == id)
        try await waitForRoot("sleep", of: id, in: manager)
        #expect(try await manager.stop(id) == .stopped)
    }

    @Test func fallbackWritesNoticeAndRunsLoginShell() async throws {
        let manager = LaunchManager(environment: FixedShellEnvironment(.fallback(.timedOut(seconds: 10))))
        let configuration = LaunchConfiguration(
            name: "Fallback", command: "[[ -o login ]] && print login || print nonlogin", directory: "/tmp")
        let id = try await manager.start(configuration)
        #expect(try await settled(id, in: manager).state == .finished)
        try await waitForOutput("login\n", of: id, in: manager)
        let output = await manager.output(for: id)
        let notice =
            "] Couldn't load your shell environment (timed out after 10 s). The command runs with the login environment.\n"
        #expect(output.hasPrefix("["))
        #expect(output.components(separatedBy: notice).count == 2)
        #expect(output.split(separator: "\n").contains("login"))
        #expect(!output.contains("nonlogin"))
        // Every run with the fallback gets its own notice.
        #expect(try await manager.start(configuration) == id)
        _ = try await settled(id, in: manager)
        try await waitForOutput("login\n", count: 2, of: id, in: manager)
        #expect(await manager.output(for: id).components(separatedBy: notice).count == 3)
    }

    @Test func interactiveSourceRunsNonLoginWithResolvedVariables() async throws {
        let manager = LaunchManager(
            environment: FixedShellEnvironment(
                .interactive(shell: "/bin/zsh"), variables: ["BYTE_PORTS_RESOLVED": "from shell", "SHLVL": "4"]))
        let id = try await manager.start(
            .init(
                name: "Interactive",
                command:
                    #"[[ -o login ]] && print login || print nonlogin; print -r -- "$BYTE_PORTS_RESOLVED|$TERM|$NO_COLOR|$SHLVL""#,
                directory: "/tmp"))
        #expect(try await settled(id, in: manager).state == .finished)
        try await waitForOutput("from shell|", of: id, in: manager)
        let output = await manager.output(for: id)
        #expect(output.split(separator: "\n").contains("nonlogin"))
        // The resolving shell's SHLVL is dropped, so the command's zsh starts at 1 again.
        #expect(output.split(separator: "\n").contains("from shell|dumb|1|1"))
        #expect(!output.contains("Couldn't load your shell environment"))
    }

    @Test func resolutionIsCachedUntilFingerprintChanges() async throws {
        let provider = CountingShellEnvironment()
        let manager = LaunchManager(environment: provider)
        #expect(await !manager.isShellEnvironmentReady)
        async let first = manager.prepareShellEnvironment()
        async let second = manager.prepareShellEnvironment()
        #expect(await first == second)
        #expect(provider.resolutions == 1)
        #expect(await manager.isShellEnvironmentReady)
        let configuration = LaunchConfiguration(name: "Cached", command: "true", directory: "/tmp")
        let id = try await manager.start(configuration)
        _ = try await settled(id, in: manager)
        #expect(provider.resolutions == 1)
        provider.changeFingerprint()
        #expect(await !manager.isShellEnvironmentReady)
        #expect(try await manager.start(configuration) == id)
        _ = try await settled(id, in: manager)
        #expect(provider.resolutions == 2)
        #expect(try await manager.restart(id) == .stopped)
        _ = try await settled(id, in: manager)
        #expect(provider.resolutions == 2)
    }

    /// The key of a formatted text is its format; the cases with an argument use the name “Web”.
    @Test(
        arguments: [
            (LaunchError.invalidName, "Give the action a name."),
            (LaunchError.invalidCommand, "Enter a valid command."),
            (LaunchError.invalidDirectory, "Choose an existing project folder with an absolute path."),
            (LaunchError.duplicateName, "An action with this name already exists."),
            (LaunchError.busy("Web"), "An action for “%@” is already in progress."),
            (LaunchError.alreadyRunning("Web"), "“%@” is already running."),
            (LaunchError.unknownJob, "This service is no longer in the list."),
            (
                LaunchError.identityUnreadable,
                "The app can't safely identify the launched process and sent no signal. Check it in Terminal."
            ),
            (LaunchError.couldNotStop("Web"), "“%@” couldn't be stopped. Check the process in Activity Monitor."),
            (LaunchError.shuttingDown, "The app is quitting."),
        ])
    func launchErrorsHaveGermanText(error: LaunchError, key: String) throws {
        #expect(error.errorDescription == String(format: key, "Web"))
        let german = try #require(LocalizationTable.bundle("de"))
        #expect(german.localizedString(forKey: key, value: nil, table: nil) != key)
    }

    /// The slot's record once its current run has ended; Process reports an exit a moment after it happens.
    private func settled(_ id: UUID, in manager: LaunchManager) async throws -> LaunchRecord {
        for _ in 0..<60 {
            if let record = await manager.records().first(where: { $0.id == id }), !record.state.isActive {
                return record
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        let records = await manager.records()
        return try #require(records.first { $0.id == id && !$0.state.isActive })
    }

    /// Waits until the job's shell has exec'd `name`. Until then a stop can race the login shell's startup.
    private func waitForRoot(_ name: String, of id: UUID, in manager: LaunchManager) async throws {
        let inspector = NativeProcessInspector()
        for _ in 0..<60 {
            let root = await manager.records().first { $0.id == id }?.identity
            if let root, inspector.process(pid: root.pid)?.name == name { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        Issue.record("The job's shell did not exec \(name)")
    }

    /// Polls records(), as RuntimeTests does, so the run tracks the daemon while the daemon's parent still sleeps.
    /// Returns the run's state once it has finished, and the daemon whose PID the current run printed.
    private func detachedDaemon(of id: UUID, in manager: LaunchManager) async throws -> (LaunchState?, ProcessRecord) {
        let inspector = NativeProcessInspector()
        var state: LaunchState?
        var daemon: ProcessRecord?
        for _ in 0..<100 {
            state = await manager.records().first { $0.id == id }?.state
            // The current run's output follows the last separator.
            let run = await manager.output(for: id).components(separatedBy: "──── ").last ?? ""
            daemon = run.split(separator: "\n").compactMap { Int32($0) }.last.flatMap(inspector.process(pid:))
            if state == .finished, daemon != nil { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        return (state, try #require(daemon))
    }

    /// Every live process below `pid`, found through child-PID lookups.
    private func descendants(of pid: Int32) -> [ProcessRecord] {
        let inspector = NativeProcessInspector()
        var found: [ProcessRecord] = []
        var frontier = [pid]
        while let parent = frontier.popLast() {
            for child in inspector.childPIDs(of: parent) {
                guard let record = inspector.process(pid: child), record.state != .exited else { continue }
                found.append(record)
                frontier.append(child)
            }
        }
        return found
    }

    /// Kills processes a failed test left behind, unless their PIDs now belong to other processes.
    private func killLeftovers(_ processes: [ProcessRecord]) {
        for process in processes { killDaemon(process) }
    }

    /// Kills a daemon a test left behind, unless its PID now belongs to another process.
    private func killDaemon(_ daemon: ProcessRecord) {
        if NativeProcessInspector().identity(pid: daemon.identity.pid) == daemon.identity {
            kill(daemon.identity.pid, SIGKILL)
        }
    }

    /// Waits until `text` occurs `count` times. The pipe can deliver a run's last output a moment after Process
    /// reports its exit.
    private func waitForOutput(
        _ text: String, count: Int = 1, of id: UUID, in manager: LaunchManager
    ) async throws {
        func found() async -> Bool { await manager.output(for: id).components(separatedBy: text).count > count }
        for _ in 0..<60 {
            if await found() { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(await found())
    }
}
