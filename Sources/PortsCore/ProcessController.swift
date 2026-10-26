import Darwin
import Foundation

public enum ProcessAction: String, Sendable {
    case pause, resume, terminate

    public var signal: Int32 {
        switch self {
        case .pause: SIGSTOP
        case .resume: SIGCONT
        case .terminate: SIGTERM
        }
    }
}

public protocol SignalSending: Sendable {
    func send(_ signal: Int32, to pid: Int32) throws
}

public struct NativeSignalSender: SignalSending {
    public init() {}
    public func send(_ signal: Int32, to pid: Int32) throws {
        guard Darwin.kill(pid, signal) == 0 else { throw MonitorError.signalFailed(errno) }
    }
}

public struct ProcessController: Sendable {
    private let inspector: any ProcessInspecting
    private let sender: any SignalSending
    private let currentPID: Int32
    private let currentUID: UInt32

    public init(
        inspector: any ProcessInspecting = NativeProcessInspector(),
        sender: any SignalSending = NativeSignalSender(),
        currentPID: Int32 = getpid(), currentUID: UInt32 = getuid()
    ) {
        self.inspector = inspector
        self.sender = sender
        self.currentPID = currentPID
        self.currentUID = currentUID
    }

    public func isControllable(_ process: ProcessRecord) -> Bool {
        process.identity.pid > 1 && process.userID == currentUID
            && !protectedPIDs().contains(process.identity.pid)
            && !process.executable.contains(".app/Contents/")
            && !process.executable.hasPrefix("/System/")
            && !process.executable.hasPrefix("/usr/libexec/")
    }

    public func perform(_ action: ProcessAction, on expected: ProcessRecord) throws {
        guard isControllable(expected) else { throw MonitorError.protectedProcess }
        guard let live = inspector.process(pid: expected.identity.pid), live.identity == expected.identity,
            live.executable == expected.executable, live.userID == expected.userID,
            live.state != .exited
        else { throw MonitorError.processChanged }
        guard isControllable(live) else { throw MonitorError.protectedProcess }
        // A stopped process cannot handle SIGTERM until it is continued.
        if action == .terminate, live.state == .paused {
            try sender.send(SIGTERM, to: live.identity.pid)
            if inspector.process(pid: live.identity.pid)?.identity == live.identity {
                try sender.send(SIGCONT, to: live.identity.pid)
            }
        } else {
            try sender.send(action.signal, to: live.identity.pid)
        }
    }

    private func protectedPIDs() -> Set<Int32> {
        var result: Set<Int32> = [0, 1, currentPID]
        var parent = inspector.process(pid: currentPID)?.parentPID ?? 1
        while parent > 1, result.insert(parent).inserted {
            parent = inspector.process(pid: parent)?.parentPID ?? 1
        }
        return result
    }
}
