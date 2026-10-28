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
    // Ancestors can only exit, never be added; identities keep a reused PID from inheriting protection.
    private let protectedAncestors: Set<ProcessIdentity>

    public init(
        inspector: any ProcessInspecting = NativeProcessInspector(),
        sender: any SignalSending = NativeSignalSender(),
        currentPID: Int32 = getpid(), currentUID: UInt32 = getuid()
    ) {
        self.inspector = inspector
        self.sender = sender
        self.currentPID = currentPID
        self.currentUID = currentUID
        var ancestors: Set<ProcessIdentity> = []
        var parent = inspector.process(pid: currentPID)?.parentPID ?? 1
        while parent > 1, let record = inspector.process(pid: parent), ancestors.insert(record.identity).inserted {
            parent = record.parentPID
        }
        protectedAncestors = ancestors
    }

    public func isControllable(_ process: ProcessRecord) -> Bool {
        isSignallable(process) && !process.executable.contains(".app/Contents/")
    }

    public func perform(_ action: ProcessAction, on expected: ProcessRecord) throws {
        try send(action.signal, labelled: action.rawValue, to: expected, allowsAppBundles: false)
    }

    /// A detected agent the user chose to quit. Like a job member, it may run from inside an app bundle, such as the
    /// Codex CLI in ChatGPT.app; every other protection still applies.
    public func isQuittable(_ process: ProcessRecord) -> Bool { isSignallable(process) }

    /// SIGTERM to an agent the user confirmed quitting, continuing it first when it is paused.
    public func quitAgent(_ expected: ProcessRecord) throws {
        try send(SIGTERM, labelled: "quit", to: expected, allowsAppBundles: true)
    }

    /// Signals a process of a job this app launched. The job tree proves ownership, so unlike `perform`, an executable
    /// inside an app bundle, such as Electron or a tool from Xcode, may be signalled; every other check still applies.
    /// SIGTERM continues a paused process so it can handle the signal; SIGKILL needs no SIGCONT.
    func signalOwnedJobMember(_ signal: Int32, _ expected: ProcessRecord) throws {
        try send(signal, labelled: signal == SIGKILL ? "kill" : "terminate", to: expected, allowsAppBundles: true)
    }

    /// Neither launchd, this app, one of its ancestors, another user's process nor part of macOS.
    private func isSignallable(_ process: ProcessRecord) -> Bool {
        process.identity.pid > 1 && process.identity.pid != currentPID && process.userID == currentUID
            && !protectedAncestors.contains(process.identity)
            && !process.executable.hasPrefix("/System/")
            && !process.executable.hasPrefix("/usr/libexec/")
    }

    private func send(
        _ signal: Int32, labelled label: String, to expected: ProcessRecord, allowsAppBundles: Bool
    ) throws {
        let pid = expected.identity.pid
        func allowed(_ process: ProcessRecord) -> Bool {
            allowsAppBundles ? isSignallable(process) : isControllable(process)
        }
        guard allowed(expected) else { throw refusal(.protectedProcess, label, pid: pid) }
        guard let live = inspector.process(pid: pid), live.identity == expected.identity,
            live.executable == expected.executable, live.userID == expected.userID,
            live.state != .exited
        else { throw refusal(.processChanged, label, pid: pid) }
        guard allowed(live) else { throw refusal(.protectedProcess, label, pid: pid) }
        do {
            // A stopped process cannot handle SIGTERM until it is continued.
            if signal == SIGTERM, live.state == .paused {
                try sender.send(SIGTERM, to: pid)
                if inspector.process(pid: pid)?.identity == live.identity { try sender.send(SIGCONT, to: pid) }
            } else {
                try sender.send(signal, to: pid)
            }
        } catch MonitorError.signalFailed(let code) {
            PortsLog.process.error(
                "Signal \(label, privacy: .public) to pid \(pid, privacy: .public) failed: errno \(code, privacy: .public)"
            )
            throw MonitorError.signalFailed(code)
        }
        PortsLog.process.notice("Sent \(label, privacy: .public) to pid \(pid, privacy: .public)")
    }

    /// Logs why an action was refused. The executable stays out of the log; the PID is enough to correlate.
    private func refusal(_ error: MonitorError, _ label: String, pid: Int32) -> MonitorError {
        let reason = error == .protectedProcess ? "protected" : "changed"
        PortsLog.process.info(
            "Refused \(label, privacy: .public) for pid \(pid, privacy: .public): \(reason, privacy: .public)"
        )
        return error
    }
}
