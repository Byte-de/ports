import Darwin
import Foundation
import ProcessBridge

public protocol ProcessInspecting: Sendable {
    func processes() throws -> [ProcessRecord]
    func process(pid: Int32) -> ProcessRecord?
}

public struct NativeProcessInspector: ProcessInspecting {
    public init() {}

    public func processes() throws -> [ProcessRecord] {
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
            return pids.prefix(Int(count)).compactMap { process(pid: $0) }
        }
        throw MonitorError.scanFailed(
            String(
                localized: "The process list is changing too quickly. Please scan again.",
                comment: "Scan error when processes appear faster than they can be listed"))
    }

    public func process(pid: Int32) -> ProcessRecord? {
        var info = DSProcessInfo()
        guard ds_read_process(pid, &info) == 1, info.uid == getuid(), info.start_seconds > 0 else { return nil }
        let name = Self.string(&info.name)
        let executable = Self.string(&info.executable)
        let directory = Self.string(&info.working_directory)
        var bytes = [CChar](repeating: 0, count: 65_536)
        let count = ds_read_arguments(pid, &bytes, bytes.count)
        let arguments: [String] =
            count > 0
            ? bytes.prefix(Int(count)).split(separator: 0, omittingEmptySubsequences: false).dropLast().map {
                String(decoding: $0.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            } : []
        return ProcessRecord(
            identity: ProcessIdentity(
                pid: pid, startSeconds: info.start_seconds, startMicroseconds: info.start_microseconds),
            parentPID: info.parent_pid, userID: info.uid, name: name,
            executable: executable, arguments: arguments,
            workingDirectory: directory.isEmpty ? nil : directory,
            state: info.status == 4 ? .paused : (info.status == 5 ? .exited : .running),
            residentBytes: info.has_metrics == 1 ? info.resident_bytes : nil,
            cpuNanoseconds: info.has_metrics == 1 ? info.cpu_nanoseconds : nil
        )
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
    case launchFailed(String)
    case timedOut
    case outputLimit

    public var errorDescription: String? {
        switch self {
        case .scanFailed(let message), .launchFailed(let message): message
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
        case .timedOut:
            String(
                localized: "The system query took too long. The next scan will try again.",
                comment: "Error when a system query for processes or listeners did not finish in time")
        case .outputLimit:
            String(
                localized: "The system query exceeded the safe output limit.",
                comment: "Error when a system query for processes or listeners produced too much output")
        }
    }
}
