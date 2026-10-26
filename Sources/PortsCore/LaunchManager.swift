import Darwin
import Foundation

public enum LaunchState: String, Sendable { case running, finished, failed }

public struct LaunchRecord: Identifiable, Sendable {
    public let id: UUID
    public let configuration: LaunchConfiguration
    public let identity: ProcessIdentity?
    public let startedAt: Date
    public let state: LaunchState
    public let exitCode: Int32?
}

/// The pipe callback is synchronous and bounded, so noisy children cannot queue unlimited Tasks.
private final class BoundedLog: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    private var truncated = false
    private let limit = 262_144

    func append(_ bytes: Data) {
        lock.lock()
        defer { lock.unlock() }
        data.append(bytes)
        if data.count > limit {
            data = Data(data.suffix(limit))
            truncated = true
        }
    }

    func snapshot() -> String {
        lock.lock()
        defer { lock.unlock() }
        return (truncated ? "[Ältere Ausgabe verworfen · maximal 256 KB]\n" : "")
            + String(decoding: data, as: UTF8.self)
    }
}

public actor LaunchManager {
    private struct Job {
        let id: UUID
        let configuration: LaunchConfiguration
        let process: Process
        let identity: ProcessIdentity?
        let startedAt: Date
        let pipe: Pipe
        let log: BoundedLog
        var knownDescendants: [ProcessIdentity: ProcessRecord] = [:]
    }

    private let inspector = NativeProcessInspector()
    private let controller = ProcessController()
    private var jobs: [UUID: Job] = [:]
    private var busy = Set<UUID>()

    public init() {}

    @discardableResult
    public func start(_ configuration: LaunchConfiguration) throws -> UUID {
        try configuration.validate()
        let process = Process()
        let pipe = Pipe()
        let log = BoundedLog()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-l", "-c", configuration.command]
        process.currentDirectoryURL = URL(fileURLWithPath: configuration.directory, isDirectory: true)
        var environment = ProcessInfo.processInfo.environment
        environment["TERM"] = "dumb"
        environment["NO_COLOR"] = "1"
        // GUI launches have a small PATH. Login-shell configuration can extend this further.
        let inheritedPath = environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" + inheritedPath
        process.environment = environment
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let bytes = handle.availableData
            if bytes.isEmpty { handle.readabilityHandler = nil } else { log.append(bytes) }
        }
        do { try process.run() } catch {
            pipe.fileHandleForReading.readabilityHandler = nil
            pipe.fileHandleForReading.closeFile()
            pipe.fileHandleForWriting.closeFile()
            throw error
        }
        pipe.fileHandleForWriting.closeFile()
        let id = UUID()
        jobs[id] = Job(
            id: id, configuration: configuration, process: process,
            identity: inspector.process(pid: process.processIdentifier)?.identity,
            startedAt: Date(), pipe: pipe, log: log)
        pruneHistory()
        return id
    }

    public func records() -> [LaunchRecord] {
        let processes = (try? inspector.processes()) ?? []
        for id in Array(jobs.keys) {
            guard var job = jobs[id] else { continue }
            let descendants = descendants(of: job, in: processes)
            for record in descendants { job.knownDescendants[record.identity] = record }
            job.knownDescendants = job.knownDescendants.filter { identity, _ in
                processes.contains { $0.identity == identity && $0.state != .exited }
            }
            jobs[id] = job
        }
        return jobs.values.map { job in
            let active = job.process.isRunning || !job.knownDescendants.isEmpty
            let code = job.process.isRunning ? nil : job.process.terminationStatus
            return LaunchRecord(
                id: job.id, configuration: job.configuration, identity: job.identity,
                startedAt: job.startedAt, state: active ? .running : (code == 0 ? .finished : .failed),
                exitCode: active ? nil : code)
        }.sorted { $0.startedAt > $1.startedAt }
    }

    public func output(for id: UUID) -> String { jobs[id]?.log.snapshot() ?? "" }

    public func stop(_ id: UUID) async throws {
        guard busy.insert(id).inserted else {
            throw MonitorError.launchFailed("Für diesen Dienst läuft bereits eine Aktion.")
        }
        defer { busy.remove(id) }
        try await stopAndWait(id)
    }

    public func restart(_ id: UUID) async throws -> UUID {
        guard busy.insert(id).inserted else {
            throw MonitorError.launchFailed("Für diesen Dienst läuft bereits eine Aktion.")
        }
        defer { busy.remove(id) }
        guard let job = jobs[id] else { throw MonitorError.processChanged }
        try await stopAndWait(id)
        return try start(job.configuration)
    }

    private func stopAndWait(_ id: UUID) async throws {
        guard let job = jobs[id] else { throw MonitorError.processChanged }
        guard job.identity != nil || !job.process.isRunning else {
            throw MonitorError.launchFailed(
                "Die Identität des gestarteten Prozesses ist nicht lesbar. Bitte im Terminal prüfen.")
        }
        let all = try inspector.processes()
        var targets = descendants(of: job, in: all)
        for known in job.knownDescendants.values where !targets.contains(where: { $0.identity == known.identity }) {
            if inspector.process(pid: known.identity.pid)?.identity == known.identity { targets.append(known) }
        }
        if let root = job.identity, let record = inspector.process(pid: root.pid), record.identity == root {
            targets.append(record)
        }
        for record in targets where record.state != .exited {
            do { try controller.perform(.terminate, on: record) } catch MonitorError.processChanged { continue }
        }
        // Never silently escalate to SIGKILL or restart into an occupied port.
        for _ in 0..<60 {
            let remaining = targets.contains { target in
                guard let live = inspector.process(pid: target.identity.pid) else { return false }
                return live.identity == target.identity && live.state != .exited
            }
            if !remaining { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw MonitorError.launchFailed(
            "Der Dienst reagiert noch nicht auf SIGTERM. Ein Neustart wurde deshalb nicht ausgeführt.")
    }

    private func descendants(of job: Job, in processes: [ProcessRecord]) -> [ProcessRecord] {
        guard let root = job.identity,
            processes.contains(where: { $0.identity == root && $0.state != .exited })
        else { return [] }
        var parentIDs: Set<Int32> = [root.pid]
        var descendants: [ProcessRecord] = []
        var added = true
        while added {
            added = false
            for process in processes
            where parentIDs.contains(process.parentPID) && !parentIDs.contains(process.identity.pid) {
                parentIDs.insert(process.identity.pid)
                descendants.append(process)
                added = true
            }
        }
        return descendants.reversed()
    }

    private func pruneHistory() {
        let finished = jobs.values.filter { !$0.process.isRunning && $0.knownDescendants.isEmpty }
            .sorted { $0.startedAt > $1.startedAt }
        for job in finished.dropFirst(30) {
            job.pipe.fileHandleForReading.readabilityHandler = nil
            job.pipe.fileHandleForReading.closeFile()
            jobs.removeValue(forKey: job.id)
        }
    }
}
