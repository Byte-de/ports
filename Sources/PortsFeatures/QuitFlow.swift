import Foundation
import PortsCore

/// What a quit does next. The app runs each effect and feeds its result back as a transition. A transition that does
/// not fit the phase returns `.none` and changes nothing, so a result that arrives after a cancel is ignored.
///
/// A user quit asks first and never force stops unless the user chooses Force Quit. A session end (logout, restart,
/// shutdown) never asks, never force stops and always terminates, because macOS ends the app soon anyway.
public struct QuitFlow: Equatable, Sendable {
    public struct Job: Identifiable, Equatable, Sendable {
        public let id: UUID
        public let name: String

        public init(id: UUID, name: String) {
            self.id = id
            self.name = name
        }
    }

    public enum Phase: String, Equatable, Sendable {
        case confirming, stopping, unresponsive, forcing, failed, finished, cancelled
    }

    public enum Effect: Equatable, Sendable {
        case none
        /// Stop every job and end every share, waiting up to `grace` for the jobs.
        case stopAll(grace: Duration)
        /// Wait up to `grace` for the remaining jobs without signalling them again.
        case wait(grace: Duration)
        case forceStop(Set<UUID>)
        case terminate
        /// Let starts and shares happen again and keep the app running.
        case resume
    }

    /// The launched jobs that were alive when the quit began.
    public let jobs: [Job]
    public let isSessionEnd: Bool
    public private(set) var phase: Phase
    /// The jobs still alive after the last stop, wait or force stop.
    public private(set) var remaining: Set<UUID> = []
    /// The first stop went out, so a repeated begin or confirm sends no second one.
    private var hasStarted = false

    public init(jobs: [Job], isSessionEnd: Bool) {
        self.jobs = jobs
        self.isSessionEnd = isSessionEnd
        phase = isSessionEnd || jobs.isEmpty ? .stopping : .confirming
    }

    /// Neither terminating nor cancelled.
    public var isActive: Bool { phase != .finished && phase != .cancelled }

    public var remainingJobs: [Job] { jobs.filter { remaining.contains($0.id) } }

    /// Starts a flow that needs no confirmation.
    public mutating func begin() -> Effect {
        guard phase == .stopping, !hasStarted else { return .none }
        hasStarted = true
        return .stopAll(grace: isSessionEnd ? LaunchManager.sessionEndGrace : LaunchManager.gracePeriod)
    }

    public mutating func confirm() -> Effect {
        guard phase == .confirming else { return .none }
        phase = .stopping
        hasStarted = true
        return .stopAll(grace: LaunchManager.gracePeriod)
    }

    /// The result of a stop or a wait: the jobs still alive.
    public mutating func stopFinished(remaining: Set<UUID>) -> Effect {
        guard phase == .stopping, hasStarted else { return .none }
        self.remaining = remaining
        guard remaining.isEmpty || isSessionEnd else {
            phase = .unresponsive
            return .none
        }
        phase = .finished
        return .terminate
    }

    public mutating func keepWaiting() -> Effect {
        guard phase == .unresponsive else { return .none }
        phase = .stopping
        return .wait(grace: LaunchManager.gracePeriod)
    }

    public mutating func forceQuit() -> Effect {
        guard phase == .unresponsive, !isSessionEnd else { return .none }
        phase = .forcing
        return .forceStop(remaining)
    }

    /// The result of a force stop: the jobs still alive.
    public mutating func forceFinished(remaining: Set<UUID>) -> Effect {
        guard phase == .forcing else { return .none }
        self.remaining = remaining
        guard remaining.isEmpty else {
            phase = .failed
            return .none
        }
        phase = .finished
        return .terminate
    }

    /// Leaves the jobs that ignored even a force stop running without the app.
    public mutating func quitAnyway() -> Effect {
        guard phase == .failed else { return .none }
        phase = .finished
        return .terminate
    }

    public mutating func cancel() -> Effect {
        guard isActive, !isSessionEnd else { return .none }
        phase = .cancelled
        return .resume
    }
}

/// Whether a terminate request comes from a logout, restart or shutdown, which must never wait for the user.
public enum SessionEnd {
    /// How long after `NSWorkspace.willPowerOffNotification` a terminate request still counts as part of it.
    public static let powerOffWindow = Duration.seconds(30)
    /// The `kAEQuitReason` values macOS sends when the session ends.
    public static let quitReasons: Set<FourCharCode> = [kAEReallyLogOut, kAERestart, kAEShutDown, kAEQuitAll]

    /// `powerOffNoticeAge` is the time since the power-off notice, if one arrived.
    public static func isSessionEnd(quitReason: FourCharCode?, powerOffNoticeAge: Duration?) -> Bool {
        if let quitReason, quitReasons.contains(quitReason) { return true }
        guard let powerOffNoticeAge else { return false }
        return powerOffNoticeAge >= .zero && powerOffNoticeAge <= powerOffWindow
    }
}
