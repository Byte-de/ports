import Foundation

public actor CloudflareTunnelManager {
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

        func requestStop(message: String? = nil) {
            guard !stopRequested else { return }
            stopRequested = true
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
    private let startupTimeout: TimeInterval
    private var acceptingStarts = true
    private var jobs: [TunnelKey: Job] = [:]
    private var monitor: Task<Void, Never>?
    private var monitorID: UUID?

    public init(client: URL, runner: URL) {
        self.client = client
        self.runner = runner
        validateOrigin = { TunnelOriginValidator().isCurrent($0) }
        startupTimeout = 45
    }

    // Dependency injection is internal: the app always validates live ownership.
    init(
        client: URL, runner: URL, timeout: TimeInterval,
        validateOrigin: @escaping @Sendable (TunnelTarget) -> Bool
    ) {
        self.client = client
        self.runner = runner
        startupTimeout = timeout
        self.validateOrigin = validateOrigin
    }

    @discardableResult public func start(_ target: TunnelTarget) throws -> TunnelRecord {
        // The pinned vendor binary declares macOS 15 as its minimum version.
        guard #available(macOS 15, *) else { throw TunnelError.unsupportedSystem }
        guard acceptingStarts else { throw TunnelError.shuttingDown }
        if let existing = jobs[target.id], existing.process.isRunning { return existing.record }
        guard validateOrigin(target) else { throw TunnelError.serverChanged }
        guard FileManager.default.isExecutableFile(atPath: client.path),
            FileManager.default.isExecutableFile(atPath: runner.path)
        else { throw TunnelError.missingClient }
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
        process.arguments = [client.path] + Self.arguments(origin: target.id.origin, config: config)
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
            throw error
        }
        try? input.fileHandleForReading.close()
        try? output.fileHandleForWriting.close()
        jobs[target.id]?.cleanup()
        let job = Job(
            target: target, process: process, input: input, output: output,
            log: log, directory: directory, timeout: startupTimeout)
        jobs[target.id] = job
        startMonitor()
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

    public func records() -> [TunnelRecord] { jobs.values.map(\.record) }

    public func stop(_ key: TunnelKey) async throws {
        guard let job = jobs[key] else { return }
        job.requestStop()
        try await waitForExit(job)
    }

    public func shutdown() async throws {
        acceptingStarts = false
        try await stopAll()
        monitor?.cancel()
        monitor = nil
        monitorID = nil
    }

    public func stopAll() async throws {
        let active = Array(jobs.values)
        for job in active { job.requestStop() }
        for job in active { try await waitForExit(job) }
    }

    public func resumeAfterCancelledQuit() { acceptingStarts = true }

    public func dismiss(_ key: TunnelKey) {
        guard let job = jobs[key], !job.process.isRunning else { return }
        job.cleanup()
        jobs.removeValue(forKey: key)
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

    private func tick() -> Bool {
        let now = ProcessInfo.processInfo.systemUptime
        for job in jobs.values {
            let log = job.log.snapshot()
            if !job.process.isRunning {
                if job.record.phase.isActive {
                    job.record.phase = job.stopRequested && job.record.message == nil ? .stopped : .failed
                    if job.record.phase == .failed, job.record.message == nil {
                        job.record.message =
                            log.lastError ?? "Die Cloudflare-Verbindung wurde beendet. Bitte erneut versuchen."
                    }
                }
                job.cleanup()
                continue
            }
            guard !job.stopRequested else { continue }
            if now - job.checkedOriginAt >= 1 {
                job.checkedOriginAt = now
                if !validateOrigin(job.record.target) {
                    job.requestStop(message: "Server oder Port beendet. Die Freigabe wurde geschlossen.")
                    continue
                }
            }
            if (!log.wasConnected || log.publicURL == nil) && now >= job.deadline {
                job.requestStop(
                    message: log.lastError
                        ?? "Cloudflare antwortet nicht. Bitte Verbindung prüfen und erneut versuchen.")
                continue
            }
            job.record.publicURL = log.publicURL
            job.record.phase =
                log.connected && log.publicURL != nil ? .ready : (log.wasConnected ? .reconnecting : .starting)
        }
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
        throw TunnelError.couldNotStop
    }
}
