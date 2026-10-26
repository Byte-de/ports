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
            guard count >= 0 else { throw MonitorError.scanFailed("Die Prozessliste ist nicht verfügbar.") }
            if count >= capacity {
                capacity *= 2
                continue
            }
            return pids.prefix(Int(count)).compactMap { process(pid: $0) }
        }
        throw MonitorError.scanFailed("Die Prozessliste ändert sich zu schnell. Bitte erneut scannen.")
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
            "Der Prozess wurde bereits beendet oder seine Identität hat sich geändert. Die Liste wird aktualisiert."
        case .protectedProcess: "Dieser Prozess ist geschützt. Öffne die zugehörige App, um ihn dort zu verwalten."
        case .signalFailed(let code): "Die Aktion konnte nicht ausgeführt werden (Systemfehler \(code))."
        case .timedOut: "Die Systemabfrage hat zu lange gedauert. Der nächste Scan versucht es erneut."
        case .outputLimit: "Die Systemabfrage hat das sichere Ausgabelimit überschritten."
        }
    }
}
