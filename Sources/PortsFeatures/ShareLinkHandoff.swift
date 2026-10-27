import PortsCore

/// A share click may copy its link without a second click only shortly afterwards and only while the pasteboard
/// still holds what it held at the click.
public struct ShareLinkHandoff: Equatable, Sendable {
    public enum Decision: Equatable, Sendable {
        /// The share is still coming up.
        case wait
        case copy
        /// Too late or the user copied something else: the link stays in the share's row.
        case offer
        /// The share ended without a link.
        case discard
    }

    /// A quick tunnel is usually ready within a few seconds; later the user has moved on.
    public static let window = Duration.seconds(15)

    public let pasteboardChangeCount: Int
    /// The continuous clock keeps counting through sleep, so a share that comes up after a wake never copies.
    public let deadline: ContinuousClock.Instant

    public init(pasteboardChangeCount: Int, clickedAt: ContinuousClock.Instant) {
        self.pasteboardChangeCount = pasteboardChangeCount
        deadline = clickedAt + Self.window
    }

    public func decide(
        phase: TunnelPhase, hasURL: Bool, pasteboardChangeCount: Int, now: ContinuousClock.Instant
    ) -> Decision {
        guard phase.isActive else { return .discard }
        guard phase == .ready, hasURL else { return .wait }
        return now <= deadline && pasteboardChangeCount == self.pasteboardChangeCount ? .copy : .offer
    }
}
