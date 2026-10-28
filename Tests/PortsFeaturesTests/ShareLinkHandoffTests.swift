import PortsCore
import PortsFeatures
import Testing

struct ShareLinkHandoffTests {
    private let click = ContinuousClock.now
    private var handoff: ShareLinkHandoff { ShareLinkHandoff(clickedAt: click) }

    private func decide(_ phase: TunnelPhase, hasURL: Bool = true, after seconds: Double = 3)
        -> ShareLinkHandoff.Decision
    {
        handoff.decide(phase: phase, hasURL: hasURL, now: click + .seconds(seconds))
    }

    @Test func copiesWhenReadyInsideWindow() {
        #expect(decide(.ready) == .copy)
        #expect(decide(.ready, after: 0) == .copy)
        // The slowest start the manager allows still copies.
        #expect(decide(.ready, after: 47) == .copy)
        #expect(decide(.ready, after: 60) == .copy)
    }

    @Test func offersWhenReadyAfterWindow() {
        #expect(ShareLinkHandoff.window == .seconds(60))
        #expect(decide(.ready, after: 60.1) == .offer)
        #expect(decide(.ready, after: 3600) == .offer)
    }

    @Test func waitsWhileStartingOrReconnecting() {
        for phase in [TunnelPhase.starting, .reconnecting, .stopping] {
            #expect(decide(phase) == .wait)
            #expect(decide(phase, hasURL: false) == .wait)
            // A slow start must not use up the copy before the link exists.
            #expect(decide(phase, after: 120) == .wait)
        }
    }

    @Test func waitsWhenReadyWithoutURL() {
        #expect(decide(.ready, hasURL: false) == .wait)
        #expect(decide(.ready, hasURL: false, after: 120) == .wait)
    }

    @Test func discardsWhenStoppedOrFailed() {
        for phase in [TunnelPhase.stopped, .failed] {
            #expect(decide(phase) == .discard)
            #expect(decide(phase, hasURL: false, after: 120) == .discard)
        }
    }
}
