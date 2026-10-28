import Darwin
import Foundation
import ProcessBridge

public protocol ProcessInspecting: Sendable {
    func processes() throws -> [ProcessRecord]
    /// Like `processes()`, but takes argv from `cache` while a settled process image is unchanged.
    func processes(reusing cache: inout ArgumentCache) throws -> [ProcessRecord]
    func process(pid: Int32) -> ProcessRecord?
    /// nil when the process is gone, a zombie or unreadable. Reads neither argv nor the executable path.
    func identity(pid: Int32) -> ProcessIdentity?
    /// The children of `pid`, zombies included. Any of them can exit or be reused before it is read.
    func childPIDs(of pid: Int32) -> [Int32]
    /// nil when the process is gone or the inspector cannot read sessions.
    func sessionID(pid: Int32) -> Int32?
}

extension ProcessInspecting {
    public func processes(reusing cache: inout ArgumentCache) throws -> [ProcessRecord] { try processes() }

    public func identity(pid: Int32) -> ProcessIdentity? {
        process(pid: pid).flatMap { $0.state == .exited ? nil : $0.identity }
    }

    public func childPIDs(of pid: Int32) -> [Int32] {
        ((try? processes()) ?? []).filter { $0.parentPID == pid }.map(\.identity.pid)
    }

    public func sessionID(pid: Int32) -> Int32? { nil }
}

/// exec replaces argv, so an entry stays valid only while identity, executable path, process name and exec state are
/// unchanged (a forked child that has not exec'd yet shows its parent's argv). argv can also be rewritten in place
/// without an exec (node `process.title`, `$0`, setproctitle; npm does it twice while starting), so a process is only
/// cached once it is `settleSeconds` old. Later in-place rewrites are missed for cached processes; listener owners
/// are always re-read through `process(pid:)`.
public struct ArgumentCache: Sendable {
    static let settleSeconds: UInt64 = 5

    struct Image: Hashable, Sendable {
        let executable: String
        let name: String
        let hasExecuted: Bool
    }

    private struct Entry: Sendable {
        let image: Image
        let arguments: [String]
    }

    private var entries: [ProcessIdentity: Entry] = [:]

    public init() {}

    var count: Int { entries.count }

    /// `now` is the wall-clock time in seconds since 1970, like `identity.startSeconds`. A failed read is not cached,
    /// so a process caught in the middle of an exec is read again next time.
    mutating func arguments(
        for identity: ProcessIdentity, image: Image, now: UInt64, read: () -> [String]?
    ) -> [String] {
        guard identity.startSeconds + Self.settleSeconds <= now else { return read() ?? [] }
        if let entry = entries[identity], entry.image == image { return entry.arguments }
        let arguments = read()
        entries[identity] = arguments.map { Entry(image: image, arguments: $0) }
        return arguments ?? []
    }

    /// Drops the processes a scan no longer saw.
    mutating func retain(_ seen: Set<ProcessIdentity>) {
        entries = entries.filter { seen.contains($0.key) }
    }
}

public struct NativeProcessInspector: ProcessInspecting {
    public init() {}

    public func processes() throws -> [ProcessRecord] {
        var cache = ArgumentCache()
        return try processes(reusing: &cache)
    }

    public func processes(reusing cache: inout ArgumentCache) throws -> [ProcessRecord] {
        // Headroom covers processes appearing between the count and list calls.
        var capacity = max(256, Int(ds_list_pids(nil, 0)) + 128)
        for _ in 0..<3 {
            var pids = [Int32](repeating: 0, count: capacity)
            let count = pids.withUnsafeMutableBufferPointer { ds_list_pids($0.baseAddress, Int32(capacity)) }
            guard count >= 0 else {
                throw MonitorError.scanFailed(
                    String(localized: "The process list is not available.", comment: "Scan error"))
            }
            if count >= capacity {
                capacity *= 2
                continue
            }
            var scratch = [CChar](repeating: 0, count: 65_536)
            let now = UInt64(max(0, time(nil)))
            let records = pids.prefix(Int(count)).compactMap { pid in
                record(pid: pid) { identity, image in
                    cache.arguments(for: identity, image: image, now: now) {
                        Self.arguments(of: pid, scratch: &scratch)
                    }
                }
            }
            cache.retain(Set(records.map(\.identity)))
            return records
        }
        throw MonitorError.scanFailed(
            String(
                localized: "The process list is changing too quickly.",
                comment: "Scan error when processes appear faster than they can be listed"))
    }

    /// Always reads argv, so an exec that kept the executable and name, or a later title change, is visible here.
    public func process(pid: Int32) -> ProcessRecord? {
        record(pid: pid) { _, _ in
            var scratch = [CChar](repeating: 0, count: 65_536)
            return Self.arguments(of: pid, scratch: &scratch) ?? []
        }
    }

    public func identity(pid: Int32) -> ProcessIdentity? {
        var seconds: UInt64 = 0
        var microseconds: UInt64 = 0
        var status: Int32 = 0
        guard ds_read_identity(pid, &seconds, &microseconds, &status) == 1, seconds > 0, status != SZOMB else {
            return nil
        }
        return ProcessIdentity(pid: pid, startSeconds: seconds, startMicroseconds: microseconds)
    }

    public func childPIDs(of pid: Int32) -> [Int32] {
        var capacity = 64
        var pids: [Int32] = []
        // A full buffer may have cut the list.
        for _ in 0..<3 {
            pids = [Int32](repeating: 0, count: capacity)
            let count = pids.withUnsafeMutableBufferPointer { ds_list_child_pids(pid, $0.baseAddress, Int32(capacity)) }
            guard count >= 0 else { return [] }
            pids = Array(pids.prefix(Int(count)))
            if count < capacity { break }
            capacity *= 2
        }
        return pids
    }

    public func sessionID(pid: Int32) -> Int32? {
        guard pid > 0 else { return nil }
        let session = getsid(pid)
        return session > 0 ? session : nil
    }

    private func record(
        pid: Int32, arguments: (ProcessIdentity, ArgumentCache.Image) -> [String]
    ) -> ProcessRecord? {
        var info = DSProcessInfo()
        guard ds_read_process(pid, &info) == 1, info.uid == getuid(), info.start_seconds > 0 else { return nil }
        let identity = ProcessIdentity(
            pid: pid, startSeconds: info.start_seconds, startMicroseconds: info.start_microseconds)
        let name = Self.string(&info.name)
        let executable = Self.string(&info.executable)
        let directory = Self.string(&info.working_directory)
        return ProcessRecord(
            identity: identity, parentPID: info.parent_pid, userID: info.uid, name: name, executable: executable,
            arguments: arguments(identity, .init(executable: executable, name: name, hasExecuted: info.has_executed)),
            workingDirectory: directory.isEmpty ? nil : directory,
            state: info.status == 4 ? .paused : (info.status == 5 ? .exited : .running),
            residentBytes: info.has_metrics == 1 ? info.resident_bytes : nil,
            cpuNanoseconds: info.has_metrics == 1 ? info.cpu_nanoseconds : nil
        )
    }

    /// nil when argv cannot be read. `scratch` grows once to kern.argmax when argv does not fit.
    private static func arguments(of pid: Int32, scratch: inout [CChar]) -> [String]? {
        var count = ds_read_arguments(pid, &scratch, scratch.count)
        if count == -2 && scratch.count < 1_048_576 {
            scratch = [CChar](repeating: 0, count: 1_048_576)
            count = ds_read_arguments(pid, &scratch, scratch.count)
        }
        guard count >= 0 else { return nil }
        return scratch.withUnsafeBytes {
            $0.prefix(Int(count)).split(separator: 0, omittingEmptySubsequences: false).dropLast().map {
                String(decoding: $0, as: UTF8.self)
            }
        }
    }

    private static func string<T>(_ tuple: inout T) -> String {
        withUnsafeBytes(of: &tuple) { bytes in
            String(decoding: bytes.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
    }
}

public enum MonitorError: LocalizedError, Sendable, Equatable {
    case scanFailed(String)
    case processChanged
    case protectedProcess
    case signalFailed(Int32)

    public var errorDescription: String? {
        switch self {
        case .scanFailed(let message): message
        case .processChanged:
            String(
                localized: "The process has already ended or its identity changed. The list will refresh.",
                comment: "Error when a process action targets a process that is gone or was replaced")
        case .protectedProcess:
            String(
                localized: "This process is protected. Open its app to manage it there.",
                comment: "Error when stopping a process that belongs to a desktop app")
        case .signalFailed(let code):
            String(
                localized: "The action could not be completed (system error \(code)).",
                comment: "Error when signalling a process failed; the argument is the errno code")
        }
    }
}
