import Foundation

public actor CloudflareTunnelManager {
    /// Why the app ended a share. The case label goes to the log.
    private enum CloseReason: String { case userStopped, originGone, startupTimeout, shutdown }

    private final class Job {
        var record: TunnelRecord
        let process: Process
        let input: Pipe
        let output: Pipe
        let log: CloudflareLogBuffer
        let directory: URL
        let deadline: TimeInterval
        var checkedOriginAt: TimeInterval = 0
        var stopRequested = false
        var closeReason: CloseReason?
        var cleanedUp = false

        init(
            target: TunnelTarget, process: Process, input: Pipe, output: Pipe,
            log: CloudflareLogBuffer, directory: URL, timeout: TimeInterval
        ) {
            record = TunnelRecord(target: target, sessionID: UUID(), phase: .starting)
            self.process = process
            self.input = input
            self.output = output
            self.log = log
            self.directory = directory
            deadline = ProcessInfo.processInfo.systemUptime + timeout
        }

        func requestStop(_ reason: CloseReason, message: String? = nil) {
            guard !stopRequested else { return }
            stopRequested = true
            closeReason = reason
            record.phase = .stopping
            record.message = message
            try? input.fileHandleForWriting.close()
        }

        func cleanup() {
            guard !cleanedUp else { return }
            cleanedUp = true
            output.fileHandleForReading.readabilityHandler = nil
            try? output.fileHandleForReading.close()
            try? input.fileHandleForWriting.close()
            try? FileManager.default.removeItem(at: directory)
        }
    }

    private let client: URL
    private let runner: URL
    private let validateOrigin: @Sendable (TunnelTarget) -> Bool
    private let probeOrigin: @Sendable (URL) async -> HTTPOriginVerdict
    private let startupTimeout: TimeInterval
    private var acceptingStarts = true
    /// Bumped by every stop-all, so a start suspended in the probe cannot launch after it.
    private var stopGeneration = 0
    private var jobs: [TunnelKey: Job] = [:]
    /// Starts suspended in the HTTP probe. A second click on the same server joins the first instead of probing again.
    private var pendingStarts: [TunnelKey: Task<TunnelRecord, any Error>] = [:]
    private var monitor: Task<Void, Never>?
    private var monitorID: UUID?
    private var observers: [UUID: AsyncStream<[TunnelRecord]>.Continuation] = [:]
    /// The snapshot every observer last received.
    private var published: [TunnelRecord] = []

    public init(client: URL, runner: URL) {
        self.client = client
        self.runner = runner
        validateOrigin = { TunnelOriginValidator().isCurrent($0) }
        probeOrigin = { await HTTPOriginProbe().verdict(for: $0) }
        startupTimeout = 45
    }

    // Dependency injection is internal: the app always validates live ownership and probes for HTTP.
    init(
        client: URL, runner: URL, timeout: TimeInterval,
        validateOrigin: @escaping @Sendable (TunnelTarget) -> Bool,
        probeOrigin: @escaping @Sendable (URL) async -> HTTPOriginVerdict = { _ in .http }
    ) {
        self.client = client
        self.runner = runner
        startupTimeout = timeout
        self.validateOrigin = validateOrigin
        self.probeOrigin = probeOrigin
    }

    deinit { for observer in observers.values { observer.finish() } }

    /// The current snapshot first, then only changed snapshots. A slow consumer gets the newest one. Shutdown keeps
    /// the stream open, because a cancelled quit keeps the app running.
    public func updates() -> AsyncStream<[TunnelRecord]> {
        // Brings existing observers up to date, so this one never receives its first snapshot twice.
        publish()
        let (stream, continuation) = AsyncStream.makeStream(
            of: [TunnelRecord].self, bufferingPolicy: .bufferingNewest(1))
        let id = UUID()
        observers[id] = continuation
        continuation.onTermination = { [weak self] _ in Task { await self?.removeObserver(id) } }
        continuation.yield(published)
        return stream
    }

    var observerCount: Int { observers.count }

    private func removeObserver(_ id: UUID) { observers[id] = nil }

    /// Every change to a record ends here before the actor suspends or returns, so `published` matches `records()`
    /// whenever another caller runs.
    private func publish() {
        let current = records()
        guard current != published else { return }
        let phases = Dictionary(published.map { ($0.sessionID, $0.phase) }) { first, _ in first }
        for record in current where phases[record.sessionID] != record.phase { logPhase(of: record) }
        published = current
        for observer in observers.values { observer.yield(current) }
    }

    /// The failure text is what the share's row shows; the close reason says which side ended the share.
    private func logPhase(of record: TunnelRecord) {
        let session = record.sessionID
        PortsLog.tunnel.info(
            "Share \(session, privacy: .public) phase \(String(describing: record.phase), privacy: .public)")
        switch record.phase {
        case .ready:
            if let url = record.publicURL {
                PortsLog.tunnel.notice("Share \(session, privacy: .public) ready at \(url, privacy: .private)")
            }
        case .failed:
            PortsLog.tunnel.error(
                "Share \(session, privacy: .public) failed: \(record.message ?? "", privacy: .private)")
            fallthrough
        case .stopped:
            // A client that exited on its own has no reason.
            if let reason = jobs[record.id]?.closeReason {
                PortsLog.tunnel.notice(
                    "Share \(session, privacy: .public) closed: \(reason.rawValue, privacy: .public)")
            }
        case .starting, .reconnecting, .stopping: break
        }
    }

    @discardableResult public func start(_ target: TunnelTarget) async throws -> TunnelRecord {
        guard acceptingStarts else { throw TunnelError.shuttingDown }
        if let existing = jobs[target.id], existing.process.isRunning { return existing.record }
        if let pending = pendingStarts[target.id] { return try await pending.value }
        let task = Task { try await self.prepareAndLaunch(target) }
        pendingStarts[target.id] = task
        defer { pendingStarts[target.id] = nil }
        return try await task.value
    }

    private func prepareAndLaunch(_ target: TunnelTarget) async throws -> TunnelRecord {
        guard validateOrigin(target) else {
            PortsLog.tunnel.info("Share refused for port \(target.id.port, privacy: .public): server changed")
            throw TunnelError.serverChanged
        }
        guard FileManager.default.isExecutableFile(atPath: client.path),
            FileManager.default.isExecutableFile(atPath: runner.path)
        else {
            PortsLog.tunnel.error("Share refused for port \(target.id.port, privacy: .public): client missing")
            throw TunnelError.missingClient
        }
        let generation = stopGeneration
        let verdict = await probeOrigin(target.origin)
        PortsLog.tunnel.info(
            "Probe verdict \(String(describing: verdict), privacy: .public) for port \(target.id.port, privacy: .public)"
        )
        switch verdict {
        case .notHTTP: throw TunnelError.notHTTP
        // Refused: the server closed its port after the scan.
        case .unreachable: throw TunnelError.serverChanged
        // A server that is slow to answer, such as one compiling its first page, is still shared.
        case .http, .inconclusive: break
        }
        // Shutdown or a stop-all, such as switching to demo mode, can run while the probe is suspended.
        guard acceptingStarts else { throw TunnelError.shuttingDown }
        guard generation == stopGeneration else { throw CancellationError() }
        return try launch(target)
    }

    private func launch(_ target: TunnelTarget) throws -> TunnelRecord {
        let directory = FileManager.default.temporaryDirectory.appending(path: "ports-tunnel-\(UUID())")
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let config = directory.appending(path: "config.yml")
        do {
            try Data("{}\n".utf8).write(to: config, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: config.path)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }

        let process = Process()
        let input = Pipe()
        let output = Pipe()
        let log = CloudflareLogBuffer()
        process.executableURL = runner
        process.arguments = [client.path] + Self.arguments(origin: target.origin, config: config)
        process.currentDirectoryURL = directory
        // Do not import existing tunnel tokens, user config, credentials or proxy overrides.
        process.environment = [
            "PATH": "/usr/bin:/bin", "HOME": directory.path, "TMPDIR": directory.path,
            "NO_COLOR": "1",
        ]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = output
        output.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil } else { log.append(data) }
        }
        do { try process.run() } catch {
            output.fileHandleForReading.readabilityHandler = nil
            try? output.fileHandleForReading.close()
            try? output.fileHandleForWriting.close()
            try? input.fileHandleForReading.close()
            try? input.fileHandleForWriting.close()
            try? FileManager.default.removeItem(at: directory)
            let failure = error as NSError
            PortsLog.tunnel.error(
                "Share client for port \(target.id.port, privacy: .public) failed to start: \(failure.domain, privacy: .public) \(failure.code, privacy: .public)"
            )
            throw error
        }
        try? input.fileHandleForReading.close()
        try? output.fileHandleForWriting.close()
        jobs[target.id]?.cleanup()
        let job = Job(
            target: target, process: process, input: input, output: output,
            log: log, directory: directory, timeout: startupTimeout)
        jobs[target.id] = job
        PortsLog.tunnel.notice(
            "Starting share \(job.record.sessionID, privacy: .public) for port \(target.id.port, privacy: .public): \(target.origin, privacy: .private)"
        )
        startMonitor()
        publish()
        return job.record
    }

    static func arguments(origin: URL, config: URL) -> [String] {
        let host = origin.host ?? "localhost"
        let authority =
            (host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host)
            + (origin.port.map { ":\($0)" } ?? "")
        return [
            "tunnel", "--config", config.path, "--no-autoupdate", "--output", "json",
            "--protocol", "auto", "--metrics", "127.0.0.1:0", "--grace-period", "1s",
            "--url", origin.absoluteString,
            "--http-host-header", authority,
        ]
    }

    /// A stable order: dictionary order changes whenever a share is added or removed.
    public func records() -> [TunnelRecord] {
        jobs.values.map(\.record).sorted {
            ($0.id.port, $0.id.process.pid, $0.sessionID) < ($1.id.port, $1.id.process.pid, $1.sessionID)
        }
    }

    public func stop(_ key: TunnelKey) async throws {
        guard let job = jobs[key] else { return }
        job.requestStop(.userStopped)
        publish()
        try await waitForExit(job)
    }

    public func shutdown() async throws {
        acceptingStarts = false
        try await stopAll(reason: .shutdown)
        monitor?.cancel()
        monitor = nil
        monitorID = nil
    }

    public func stopAll() async throws { try await stopAll(reason: .userStopped) }

    private func stopAll(reason: CloseReason) async throws {
        stopGeneration += 1
        // A share that already ended keeps its failure notice until the user dismisses it. A client that exited
        // before the monitor noticed still counts, so no record stays active without a process.
        let active = jobs.values.filter(\.record.phase.isActive)
        for job in active { job.requestStop(reason) }
        publish()
        for job in active { try await waitForExit(job) }
    }

    public func resumeAfterCancelledQuit() { acceptingStarts = true }

    public func dismiss(_ key: TunnelKey) {
        guard let job = jobs[key], !job.process.isRunning else { return }
        job.cleanup()
        jobs.removeValue(forKey: key)
        publish()
    }

    private func startMonitor() {
        guard monitor == nil else { return }
        let id = UUID()
        monitorID = id
        monitor = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, await self.monitorTick(id) else { break }
                do { try await Task.sleep(for: .milliseconds(500)) } catch { break }
            }
        }
    }

    private func monitorTick(_ id: UUID) -> Bool {
        guard monitorID == id else { return false }
        if tick() { return true }
        monitor = nil
        monitorID = nil
        return false
    }

    /// Runs every 500 ms only while a child runs, and once more when a stop sees its child exit.
    private func tick() -> Bool {
        let now = ProcessInfo.processInfo.systemUptime
        for job in jobs.values {
            let log = job.log.snapshot()
            if !job.process.isRunning {
                if job.record.phase.isActive {
                    job.record.phase = job.stopRequested && job.record.message == nil ? .stopped : .failed
                    if job.record.phase == .failed, job.record.message == nil {
                        // cloudflared's own error text is shown as is.
                        job.record.message =
                            log.lastError
                            ?? String(
                                localized: "The Cloudflare connection ended. Please try again.",
                                comment: "Public share status when the Cloudflare connection process exited")
                    }
                }
                job.cleanup()
                continue
            }
            guard !job.stopRequested else { continue }
            if now - job.checkedOriginAt >= 1 {
                job.checkedOriginAt = now
                if !validateOrigin(job.record.target) {
                    job.requestStop(
                        .originGone,
                        message: String(
                            localized: "The server or port stopped. Sharing was closed.",
                            comment: "Public share status when the shared server or its port went away"))
                    continue
                }
            }
            if (!log.wasConnected || log.publicURL == nil) && now >= job.deadline {
                job.requestStop(
                    .startupTimeout,
                    message: log.lastError
                        ?? String(
                            localized: "Cloudflare is not responding. Check your connection and try again.",
                            comment: "Public share status when Cloudflare did not connect in time"))
                continue
            }
            job.record.publicURL = log.publicURL
            job.record.phase =
                log.connected && log.publicURL != nil ? .ready : (log.wasConnected ? .reconnecting : .starting)
        }
        publish()
        return jobs.values.contains { $0.process.isRunning }
    }

    private func waitForExit(_ job: Job) async throws {
        for _ in 0..<80 {
            if !job.process.isRunning {
                _ = tick()
                return
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        PortsLog.tunnel.error("Share \(job.record.sessionID, privacy: .public) client still running after the stop")
        throw TunnelError.couldNotStop
    }
}
