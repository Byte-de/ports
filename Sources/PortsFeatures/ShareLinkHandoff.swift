import PortsCore

/// A share click copies its link as soon as the share is ready, without a second click. Only a link that arrives
/// long after the click, such as after the Mac slept, is offered instead.
public struct ShareLinkHandoff: Equatable, Sendable {
    public enum Decision: Equatable, Sendable {
        /// The share is still coming up.
        case wait
        case copy
        /// Too late: the link stays in the share's row.
        case offer
        /// The share ended without a link.
        case discard
    }

    /// Longer than a start may take (45 s plus the HTTP check), so only a share that came up after a sleep misses it.
    public static let window = Duration.seconds(60)

    /// The continuous clock keeps counting through sleep, so a share that comes up after a wake never copies.
    public let deadline: ContinuousClock.Instant

    public init(clickedAt: ContinuousClock.Instant) {
        deadline = clickedAt + Self.window
    }

    public func decide(phase: TunnelPhase, hasURL: Bool, now: ContinuousClock.Instant) -> Decision {
        guard phase.isActive else { return .discard }
        guard phase == .ready, hasURL else { return .wait }
        return now <= deadline ? .copy : .offer
    }
}
