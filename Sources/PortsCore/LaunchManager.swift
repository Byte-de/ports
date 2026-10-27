import Darwin
import Foundation

public enum LaunchState: String, Sendable {
    case running
    /// A stop or wait is in progress.
    case stopping
    /// Still alive after a stop's grace period. Only a force stop ends it, unless it exits on its own.
    case unresponsive
    /// Ended after the user stopped it.
    case stopped
    /// Exited with status 0 on its own.
    case finished
    /// Exited with another status, or by a signal, on its own.
    case failed

    /// A process of the job is still alive.
    public var isActive: Bool { self == .running || self == .stopping || self == .unresponsive }
}

/// Whether a job ended within the time a stop gave it. A stop never escalates on its own: a job that is still running
/// stays alive until it exits or the user force stops it.
public enum StopOutcome: Sendable, Equatable { case stopped, stillRunning }

/// A configuration's slot: every start and restart of the configuration reuses it, and its log spans every run.
public struct LaunchRecord: Identifiable, Equatable, Sendable {
    /// The configuration's id.
    public let id: UUID
    /// New on every start.
    public let runID: UUID
    /// The configuration of the current run, as it was when the run started.
    public let configuration: LaunchConfiguration
    public let identity: ProcessIdentity?
    /// The slot's first start, which keeps its place in the list across restarts.
    public let createdAt: Date
    public let startedAt: Date
    public let runCount: Int
    public let state: LaunchState
    public let exitCode: Int32?
}

/// Output read since a cursor returned by an earlier read.
public struct LaunchOutput: Sendable, Equatable {
    public let text: String
    /// Pass this to the next read to receive only newer output.
    public let cursor: UInt64
    /// The text replaces everything shown before, because the cursor was missing or no longer valid.
    public let reset: Bool
    /// Older output was discarded.
    public let truncated: Bool
}

public enum LaunchError: LocalizedError, Equatable, Sendable {
    case invalidName, invalidCommand, invalidDirectory, duplicateName
    case busy(String)
    case alreadyRunning(String)
    case unknownJob
    case identityUnreadable
    case couldNotStop(String)
    case shuttingDown

    public var errorDescription: String? {
        switch self {
        case .invalidName:
            String(localized: "Give the action a name.", comment: "Validation error for an action without a name")
        case .invalidCommand:
            String(localized: "Enter a valid command.", comment: "Validation error for an empty or malformed command")
        case .invalidDirectory:
            String(
                localized: "Choose an existing project folder with an absolute path.",
                comment: "Validation error for a missing or relative project folder")
        case .duplicateName:
            String(
                localized: "An action with this name already exists.",
                comment: "Validation error when another saved action already has the name")
        case .busy(let name):
            String(
                localized: "An action for “\(name)” is already in progress.",
                comment: "Error when an action targets a launched service that is busy; the argument is its name")
        case .alreadyRunning(let name):
            String(
                localized: "“\(name)” is already running.",
                comment: "Error when an action that still runs is started again; the argument is its name")
        case .unknownJob:
            String(
                localized: "This service is no longer in the list.",
                comment: "Error when an action targets a launched service that was removed from the list")
        case .identityUnreadable:
            String(
                localized:
                    "The app can't safely identify the launched process and sent no signal. Check it in Terminal.",
                comment: "Error when stopping a launched service whose process identity could not be read")
        case .couldNotStop(let name):
            String(
                localized: "“\(name)” couldn't be stopped. Check the process in Activity Monitor.",
                comment: "Error when a launched service did not exit after it was asked to; the argument is its name")
        case .shuttingDown:
            String(localized: "The app is quitting.", comment: "Error when an action is started while the app quits")
        }
    }
}

public actor LaunchManager {
    /// How long a stop waits after SIGTERM before it reports the job as unresponsive.
    public static let gracePeriod: Duration = .seconds(15)
    /// What a logout, restart or shutdown leaves before macOS ends the app.
    public static let sessionEndGrace: Duration = .seconds(5)
    /// How long a force stop watches the job after SIGKILL.
    public static let forceWait: Duration = .seconds(2)
    /// How long starts reuse a fallback environment before they try the user's shell again.
    public static let fallbackEnvironmentLifetime: Duration = .seconds(300)
    private static let poll: Duration = .milliseconds(100)
    /// Core has no AppInfo, so it reads the brand itself. Unbundled runs fall back to the product name.
    private static let brand =
        Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "Byte Ports"

    private struct Run {
        let id: UUID
        let configuration: LaunchConfiguration
        let process: Process
        let identity: ProcessIdentity?
        let session: Int32?
        let startedAt: Date
        let pipe: Pipe
        var knownDescendants: [ProcessIdentity: ProcessRecord] = [:]
        /// The user asked the run to stop, so its end counts as stopped rather than finished or failed.
        var stopRequested = false
        /// A stop's grace period ran out while the run was alive.
        var unresponsive = false
    }

    /// What a stop waits for: the run's root and the descendants it signalled or could not reach.
    private struct Pending {
        let run: UUID
        let root: Process
        let descendants: [ProcessRecord]
    }

    private struct Slot {
        let id: UUID
        let createdAt: Date
        let log: BoundedLog
        var run: Run
        var runCount: Int
    }

    private struct ResolvedEnvironment {
        let fingerprint: String
        let environment: ShellEnvironment
        let resolvedAt: ContinuousClock.Instant
    }

    private static let retainedInactiveSlots = 30

    /// Yields a slot's id whenever one of its runs exits.
    public nonisolated let changes: AsyncStream<UUID>
    private let changesContinuation: AsyncStream<UUID>.Continuation
    private let inspector = NativeProcessInspector()
    private let controller = ProcessController()
    private var slots: [UUID: Slot] = [:]
    private var busy = Set<UUID>()
    /// Slots a stop, force stop or wait is waiting for.
    private var stopping = Set<UUID>()
    /// Off from `stopAll(grace:)` until `resumeAfterCancelledQuit()`.
    private var acceptingStarts = true
    private let shellEnvironment: any ShellEnvironmentProviding
    private var resolvedEnvironment: ResolvedEnvironment?
    /// The resolution in progress, which concurrent starts share.
    private var environmentTask: (fingerprint: String, task: Task<ShellEnvironment, Never>)?

    public init(environment: any ShellEnvironmentProviding = InteractiveShellEnvironment()) {
        let (stream, continuation) = AsyncStream.makeStream(of: UUID.self, bufferingPolicy: .bufferingNewest(32))
        changes = stream
        changesContinuation = continuation
        shellEnvironment = environment
    }

    deinit { changesContinuation.finish() }

    /// Starts the configuration in its slot. A configuration that ran before reuses its slot and log. The first start
    /// of a session waits for the shell environment.
    @discardableResult
    public func start(_ configuration: LaunchConfiguration) async throws -> UUID {
        try configuration.validate()
        let id = configuration.id
        guard acceptingStarts else { throw LaunchError.shuttingDown }
        guard !isBusy(id) else { throw LaunchError.busy(configuration.name) }
        guard refreshedState(of: id)?.isActive != true else { throw LaunchError.alreadyRunning(configuration.name) }
        busy.insert(id)
        defer { busy.remove(id) }
        let environment = await prepareShellEnvironment()
        // A quit may have begun while the shell environment loaded.
        guard acceptingStarts else { throw LaunchError.shuttingDown }
        guard refreshedState(of: id)?.isActive != true else { throw LaunchError.alreadyRunning(configuration.name) }
        try launch(configuration, restarting: false, environment: environment)
        return id
    }

    /// Whether a start can use the shell environment without running the user's shell first.
    public var isShellEnvironmentReady: Bool { currentEnvironment(for: shellEnvironment.fingerprint()) != nil }

    /// Reads the user's shell environment unless a current one is cached. Concurrent callers share one resolution. The
    /// result is reused until a shell startup file changes; a fallback for `fallbackEnvironmentLifetime` at most.
    @discardableResult
    public func prepareShellEnvironment() async -> ShellEnvironment {
        let fingerprint = shellEnvironment.fingerprint()
        if let environment = currentEnvironment(for: fingerprint) { return environment }
        if let pending = environmentTask, pending.fingerprint == fingerprint { return await pending.task.value }
        let provider = shellEnvironment
        let base = ProcessInfo.processInfo.environment
        let task = Task {
            let clock = ContinuousClock()
            let started = clock.now
            let environment = await provider.resolve(base: base)
            let milliseconds = Int(started.duration(to: clock.now) / .milliseconds(1))
            // The source only: values are never logged.
            PortsLog.launch.info(
                "Shell environment: \(environment.source.logKey, privacy: .public) in \(milliseconds, privacy: .public) ms"
            )
            return environment
        }
        environmentTask = (fingerprint, task)
        let environment = await task.value
        if environmentTask?.task == task {
            environmentTask = nil
            resolvedEnvironment = ResolvedEnvironment(
                fingerprint: fingerprint, environment: environment, resolvedAt: .now)
        }
        return environment
    }

    /// Stops the slot's run and starts it again in the same slot. `configuration`, such as an edited saved action,
    /// replaces the one the slot ran last and must have the slot's id. A run that is still alive after `grace` keeps
    /// running and nothing starts: the result is `.stillRunning`.
    public func restart(
        _ id: UUID, using configuration: LaunchConfiguration? = nil, grace: Duration = LaunchManager.gracePeriod
    ) async throws -> StopOutcome {
        guard let slot = slots[id], configuration.map({ $0.id == id }) ?? true else { throw LaunchError.unknownJob }
        guard !isBusy(id) else { throw LaunchError.busy(slot.run.configuration.name) }
        guard acceptingStarts else { throw LaunchError.shuttingDown }
        let next = configuration ?? slot.run.configuration
        // An unusable configuration must not cost the running service.
        try next.validate()
        busy.insert(id)
        defer { busy.remove(id) }
        // Loaded before the stop, so the service keeps running while the user's shell starts.
        let environment = await prepareShellEnvironment()
        guard acceptingStarts else { throw LaunchError.shuttingDown }
        guard try await end(id, signalling: true, grace: grace) == .stopped else { return .stillRunning }
        // A quit may have begun during the wait.
        guard acceptingStarts else { throw LaunchError.shuttingDown }
        try launch(next, restarting: true, environment: environment)
        PortsLog.launch.notice("Restarted job \(id, privacy: .public)")
        return .stopped
    }

    /// Sends SIGTERM to the slot's run and waits up to `grace` for it to exit. Never escalates: a run that is still
    /// alive afterwards stays `.unresponsive` until it exits or `forceStop(_:run:)` ends it.
    @discardableResult
    public func stop(_ id: UUID, grace: Duration = LaunchManager.gracePeriod) async throws -> StopOutcome {
        guard let slot = slots[id] else { throw LaunchError.unknownJob }
        guard !isBusy(id) else { throw LaunchError.busy(slot.run.configuration.name) }
        busy.insert(id)
        defer { busy.remove(id) }
        return try await end(id, signalling: true, grace: grace)
    }

    /// Waits up to `grace` for the slot's run to exit, like `stop(_:grace:)` but without signalling it again.
    @discardableResult
    public func waitForExit(_ id: UUID, grace: Duration = LaunchManager.gracePeriod) async throws -> StopOutcome {
        guard let slot = slots[id] else { throw LaunchError.unknownJob }
        guard !isBusy(id) else { throw LaunchError.busy(slot.run.configuration.name) }
        busy.insert(id)
        defer { busy.remove(id) }
        return try await end(id, signalling: false, grace: grace)
    }

    /// Sends SIGKILL to the run's live processes and watches them for `forceWait`. `run` is the run the user chose to
    /// force stop, so a run that started since is never killed. Daemons that detached are left alone, as in a stop.
    @discardableResult
    public func forceStop(_ id: UUID, run: UUID) async throws -> StopOutcome {
        guard let slot = slots[id], slot.run.id == run else { throw LaunchError.unknownJob }
        guard refreshedState(of: id)?.isActive == true else { return .stopped }
        guard slot.run.identity != nil || !slot.run.process.isRunning else { throw LaunchError.identityUnreadable }
        return await force([id]).isEmpty ? .stopped : .stillRunning
    }

    /// Stops every live job at once for a quit, and refuses starts until `resumeAfterCancelledQuit()`. Jobs that a
    /// stop is already waiting for get no second SIGTERM. Returns the jobs still alive after `grace`.
    public func stopAll(grace: Duration = LaunchManager.gracePeriod) async -> Set<UUID> {
        acceptingStarts = false
        var pending: [UUID: Pending] = [:]
        // Without the root's identity nothing can be signalled safely, so waiting would only take time.
        var unreadable = Set<UUID>()
        for id in Array(slots.keys) where refreshedState(of: id)?.isActive == true {
            guard let run = slots[id]?.run, run.identity != nil || !run.process.isRunning else {
                unreadable.insert(id)
                continue
            }
            let signalling = !stopping.contains(id)
            if signalling { slots[id]?.run.stopRequested = true }
            pending[id] = signal(signalling ? SIGTERM : nil, id)
        }
        let alive = await wait(for: pending, grace: grace)
        logStillRunning(alive)
        return unreadable.union(alive.keys)
    }

    /// Waits up to `grace` for the given jobs without signalling them again, as when a quit keeps waiting. Returns the
    /// jobs still alive.
    public func waitForAll(_ ids: Set<UUID>, grace: Duration = LaunchManager.gracePeriod) async -> Set<UUID> {
        var pending: [UUID: Pending] = [:]
        for id in ids where refreshedState(of: id)?.isActive == true { pending[id] = signal(nil, id) }
        let alive = await wait(for: pending, grace: grace)
        logStillRunning(alive)
        return Set(alive.keys)
    }

    /// Force stops the given jobs at once, as a quit's Force Quit does. Returns the jobs still alive afterwards.
    public func forceStopAll(_ ids: Set<UUID>) async -> Set<UUID> {
        await force(ids.filter { refreshedState(of: $0)?.isActive == true })
    }

    /// Accepts starts again after a quit was cancelled.
    public func resumeAfterCancelledQuit() { acceptingStarts = true }

    /// Removes the slot and its log. false while an action for it is in progress or its job is still alive.
    public func remove(_ id: UUID) -> Bool {
        guard !isBusy(id), let state = refreshedState(of: id), !state.isActive,
            let slot = slots.removeValue(forKey: id)
        else { return false }
        Self.detach(slot.run.pipe)
        return true
    }

    /// Removes every slot that `remove(_:)` accepts and returns their ids, newest first.
    public func removeFinished() -> [UUID] {
        var removed: [UUID] = []
        for slot in slots.values.sorted(by: { $0.createdAt > $1.createdAt }) where remove(slot.id) {
            removed.append(slot.id)
        }
        return removed
    }

    /// The state of the slot's current run; nil for an unknown slot.
    public func status(for id: UUID) -> LaunchState? { refreshedState(of: id) }

    /// Newest slot first.
    public func records() -> [LaunchRecord] {
        for (id, var slot) in slots {
            refresh(&slot.run)
            slots[id] = slot
        }
        return slots.values.sorted { $0.createdAt > $1.createdAt }.map { slot in
            let outcome = outcome(of: slot)
            return LaunchRecord(
                id: slot.id, runID: slot.run.id, configuration: slot.run.configuration, identity: slot.run.identity,
                createdAt: slot.createdAt, startedAt: slot.run.startedAt, runCount: slot.runCount,
                state: outcome.state, exitCode: outcome.exitCode)
        }
    }

    public func output(for id: UUID, after cursor: UInt64?) -> LaunchOutput? {
        guard let read = slots[id]?.log.read(after: cursor) else { return nil }
        return LaunchOutput(
            text: String(decoding: read.bytes, as: UTF8.self), cursor: read.cursor, reset: read.reset,
            truncated: read.truncated)
    }

    /// The complete retained output, for copying and diagnostics.
    public func output(for id: UUID) -> String {
        guard let snapshot = slots[id]?.log.snapshot() else { return "" }
        guard snapshot.truncated else { return snapshot.text }
        let notice = String(
            localized: "[Older output discarded · 256 KB maximum]",
            comment: "First line of copied launch output when older output was dropped")
        return notice + "\n" + snapshot.text
    }

    private func currentEnvironment(for fingerprint: String) -> ShellEnvironment? {
        guard let resolved = resolvedEnvironment, resolved.fingerprint == fingerprint else { return nil }
        if case .fallback = resolved.environment.source,
            resolved.resolvedAt.duration(to: .now) >= Self.fallbackEnvironmentLifetime
        {
            return nil
        }
        return resolved.environment
    }

    /// Runs `configuration` in its slot. An existing slot keeps its log and gets a separator line before the new
    /// process starts, so all of the new run's output follows it.
    private func launch(_ configuration: LaunchConfiguration, restarting: Bool, environment: ShellEnvironment) throws {
        let id = configuration.id
        let existing = slots[id]
        let log = existing?.log ?? BoundedLog()
        if let existing {
            // A daemon the previous run left behind may still write to its pipe; that output is not this run's.
            Self.detach(existing.run.pipe)
            Self.appendSeparator(to: log, restarting: restarting)
        }
        if case .fallback(let reason) = environment.source { Self.appendFallbackNotice(reason, to: log) }
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = environment.arguments(for: configuration.command)
        process.currentDirectoryURL = URL(fileURLWithPath: configuration.directory, isDirectory: true)
        process.environment = environment.variables
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let bytes = handle.availableData
            if bytes.isEmpty { handle.readabilityHandler = nil } else { log.append(bytes) }
        }
        let changes = changesContinuation
        process.terminationHandler = { process in
            PortsLog.launch.notice(
                "Job \(id, privacy: .public) exited with status \(process.terminationStatus, privacy: .public)")
            changes.yield(id)
        }
        let runID = UUID()
        do { try process.run() } catch {
            pipe.fileHandleForReading.readabilityHandler = nil
            pipe.fileHandleForReading.closeFile()
            pipe.fileHandleForWriting.closeFile()
            throw error
        }
        pipe.fileHandleForWriting.closeFile()
        PortsLog.launch.notice(
            "Started job \(id, privacy: .public) run \(runID, privacy: .public) pid \(process.processIdentifier, privacy: .public): \(configuration.command, privacy: .private) in \(configuration.directory, privacy: .private)"
        )
        let identity = inspector.process(pid: process.processIdentifier)?.identity
        let run = Run(
            id: runID, configuration: configuration, process: process, identity: identity,
            session: identity.flatMap { inspector.sessionID(pid: $0.pid) }, startedAt: Date(), pipe: pipe)
        if var slot = existing {
            slot.run = run
            slot.runCount += 1
            slots[id] = slot
        } else {
            slots[id] = Slot(id: id, createdAt: run.startedAt, log: log, run: run, runCount: 1)
        }
        pruneHistory()
    }

    private static func appendSeparator(to log: BoundedLog, restarting: Bool) {
        let time = Date.now.formatted(Date.FormatStyle(date: .omitted, time: .standard))
        let line =
            restarting
            ? String(
                localized: "──── Restarted · \(time) ────",
                comment: "Line in launch output where a restart begins; the argument is the time")
            : String(
                localized: "──── Started again · \(time) ────",
                comment: "Line in launch output where a new start begins; the argument is the time")
        // The previous run may have ended in the middle of a line.
        let endsLine = log.written == 0 || log.read(after: log.written - 1).bytes.last == 0x0A
        log.append(Data(((endsLine ? "" : "\n") + line + "\n").utf8))
    }

    private static func appendFallbackNotice(_ reason: ShellEnvironment.FallbackReason, to log: BoundedLog) {
        let notice = String(
            localized:
                "[\(brand)] Couldn't load your shell environment (\(reason.localizedDescription)). The command runs with the login environment.",
            comment:
                "Line in launch output when a command runs without the user's shell environment; the arguments are the app's name and the reason"
        )
        log.append(Data((notice + "\n").utf8))
    }

    /// Stops logging the pipe but drains it until EOF. Only the app holds its read end, so closing it would kill a
    /// detached daemon with SIGPIPE on its next write. The handler keeps the handle alive until the last writer exits.
    private static func detach(_ pipe: Pipe) {
        let reader = pipe.fileHandleForReading
        reader.readabilityHandler = { _ in
            if reader.availableData.isEmpty { reader.readabilityHandler = nil }
        }
    }

    /// Once the root and every known descendant are gone, nothing can join the run again.
    private func refresh(_ run: inout Run) {
        guard run.process.isRunning || !run.knownDescendants.isEmpty else { return }
        run.knownDescendants = JobTree.refresh(
            known: run.knownDescendants, root: run.identity, session: run.session, inspector: inspector)
    }

    /// While the root runs, no tree walk is needed. Afterwards the walk decides, which drops descendants that
    /// detached as daemons, so they neither keep a slot running nor block its next start.
    private func refreshedState(of id: UUID) -> LaunchState? {
        guard var slot = slots[id] else { return nil }
        if !slot.run.process.isRunning {
            refresh(&slot.run)
            slots[id] = slot
        }
        return outcome(of: slot).state
    }

    private func outcome(of slot: Slot) -> (state: LaunchState, exitCode: Int32?) {
        let run = slot.run
        if run.process.isRunning || !run.knownDescendants.isEmpty {
            if stopping.contains(slot.id) { return (.stopping, nil) }
            return (run.unresponsive ? .unresponsive : .running, nil)
        }
        let code = run.process.terminationStatus
        if run.stopRequested { return (.stopped, code) }
        return (code == 0 ? .finished : .failed, code)
    }

    /// A stop, restart or wait for the slot is in progress, or a quit is waiting for it.
    private func isBusy(_ id: UUID) -> Bool { busy.contains(id) || stopping.contains(id) }

    /// Ends the slot's run gracefully: sends SIGTERM when `signalling`, then waits up to `grace`.
    private func end(_ id: UUID, signalling: Bool, grace: Duration) async throws -> StopOutcome {
        guard refreshedState(of: id)?.isActive == true else { return .stopped }
        guard let run = slots[id]?.run else { throw LaunchError.unknownJob }
        guard run.identity != nil || !run.process.isRunning else { throw LaunchError.identityUnreadable }
        if signalling { slots[id]?.run.stopRequested = true }
        var pending: [UUID: Pending] = [:]
        pending[id] = signal(signalling ? SIGTERM : nil, id)
        let alive = await wait(for: pending, grace: grace)
        logStillRunning(alive)
        return alive.isEmpty ? .stopped : .stillRunning
    }

    private func force(_ ids: Set<UUID>) async -> Set<UUID> {
        var pending: [UUID: Pending] = [:]
        for id in ids {
            slots[id]?.run.stopRequested = true
            pending[id] = signal(SIGKILL, id)
        }
        let alive = await wait(for: pending, grace: Self.forceWait)
        for id in pending.keys {
            PortsLog.launch.notice(
                "Force stopped job \(id, privacy: .public): remaining \(alive[id] ?? 0, privacy: .public)")
        }
        return Set(alive.keys)
    }

    /// Sends `signal` to the run's live processes, children before the parents that started them, and returns what
    /// to wait for. With nil, it only collects them. Processes that vanished or changed since the walk are skipped;
    /// those the signal could not reach still count.
    private func signal(_ signal: Int32?, _ id: UUID) -> Pending? {
        guard var run = slots[id]?.run else { return nil }
        let targets = stopTargets(&run)
        slots[id]?.run = run
        if signal == SIGTERM {
            PortsLog.launch.info("Stopping job \(id, privacy: .public): \(targets.count, privacy: .public) processes")
        }
        var descendants: [ProcessRecord] = []
        for target in targets {
            if let signal {
                do {
                    try controller.signalOwnedJobMember(signal, target)
                } catch MonitorError.processChanged {
                    continue
                } catch {
                    // Refused or failed, which the controller logged. The process stays alive, so the wait counts it.
                }
            }
            if target.identity != run.identity { descendants.append(target) }
        }
        return Pending(run: run.id, root: run.process, descendants: descendants)
    }

    /// Shows the slots as stopping during the wait and marks those still alive afterwards as unresponsive. Returns
    /// how many processes each of those still has.
    private func wait(for pending: [UUID: Pending], grace: Duration) async -> [UUID: Int] {
        // A slot that another wait already shows as stopping stays so until that wait ends.
        let marked = Set(pending.keys).subtracting(stopping)
        stopping.formUnion(marked)
        let alive = await waitUntilGone(pending, grace: grace)
        stopping.subtract(marked)
        for id in alive.keys where slots[id]?.run.id == pending[id]?.run { slots[id]?.run.unresponsive = true }
        return alive
    }

    /// Polls until every pending process has exited or `grace` has passed. The root counts until Process has reaped
    /// it, so a returned job's state is already final.
    private func waitUntilGone(_ pending: [UUID: Pending], grace: Duration) async -> [UUID: Int] {
        let clock = ContinuousClock()
        let deadline = clock.now + grace
        while true {
            var alive: [UUID: Int] = [:]
            for (id, entry) in pending {
                let descendants = entry.descendants.count { inspector.identity(pid: $0.identity.pid) == $0.identity }
                let count = descendants + (entry.root.isRunning ? 1 : 0)
                if count > 0 { alive[id] = count }
            }
            let left = clock.now.duration(to: deadline)
            if alive.isEmpty || left <= .zero { return alive }
            // Cancellation ends the wait; whatever is alive then counts as still running.
            do { try await Task.sleep(for: min(Self.poll, left)) } catch { return alive }
        }
    }

    private func logStillRunning(_ alive: [UUID: Int]) {
        for (id, count) in alive {
            PortsLog.launch.error(
                "Job \(id, privacy: .public) still running after grace period (\(count, privacy: .public) processes)")
        }
    }

    /// Live descendants newest-first, so children are signalled before the parents that started them, then the root.
    /// The tree walk leaves out daemons that detached, so a stop, restart or force stop never signals them.
    private func stopTargets(_ run: inout Run) -> [ProcessRecord] {
        run.knownDescendants = JobTree.refresh(
            known: run.knownDescendants, root: run.identity, session: run.session, inspector: inspector)
        var targets = run.knownDescendants.values.sorted {
            ($0.identity.startSeconds, $0.identity.startMicroseconds)
                > ($1.identity.startSeconds, $1.identity.startMicroseconds)
        }
        if let root = run.identity, let record = inspector.process(pid: root.pid), record.identity == root,
            record.state != .exited
        {
            targets.append(record)
        }
        return targets
    }

    /// Keeps the newest inactive slots. Slots with a live job or an action in progress always stay.
    private func pruneHistory() {
        let inactive = slots.values.filter { !isBusy($0.id) && !outcome(of: $0).state.isActive }
            .sorted { $0.run.startedAt > $1.run.startedAt }
        for slot in inactive.dropFirst(Self.retainedInactiveSlots) {
            Self.detach(slot.run.pipe)
            slots.removeValue(forKey: slot.id)
        }
    }
}

/// Walks a job's tree through child-PID lookups instead of enumerating every process. Known descendants stay tracked
/// after reparenting to launchd, and children they spawn later are found too.
enum JobTree {
    /// The root's live descendants, without the root. `session` is the root's session, read at start: a descendant in
    /// another session stays only while a tracked parent still has it, so a daemon that detached and was reparented to
    /// launchd is dropped with its children.
    static func refresh(
        known: [ProcessIdentity: ProcessRecord], root: ProcessIdentity?, session: Int32?,
        inspector: some ProcessInspecting
    ) -> [ProcessIdentity: ProcessRecord] {
        var survivors: [Int32: ProcessRecord] = [:]
        for identity in known.keys {
            guard let live = inspector.process(pid: identity.pid), live.identity == identity, live.state != .exited
            else { continue }
            survivors[identity.pid] = live
        }
        // Every survivor in the job's session starts a walk, not only those already reparented: a parent can exit
        // after its children were read, and launchd adopts them before the walk would look under that parent.
        var tracked: [ProcessIdentity: ProcessRecord] = [:]
        var frontier: [Int32] = []
        for record in survivors.values {
            guard session == nil || inspector.sessionID(pid: record.identity.pid) == session else { continue }
            tracked[record.identity] = record
            frontier.append(record.identity.pid)
        }
        if let root, inspector.identity(pid: root.pid) == root { frontier.append(root.pid) }
        var visited = Set(frontier)
        while let parent = frontier.popLast() {
            for pid in inspector.childPIDs(of: parent) where visited.insert(pid).inserted {
                guard let child = survivors[pid] ?? inspector.process(pid: pid), child.parentPID == parent,
                    child.state != .exited
                else { continue }
                tracked[child.identity] = child
                frontier.append(pid)
            }
        }
        return tracked
    }
}
