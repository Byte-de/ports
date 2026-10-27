import PortsCore
import PortsFeatures
import Testing

struct ShareLinkHandoffTests {
    private let click = ContinuousClock.now
    private var handoff: ShareLinkHandoff { ShareLinkHandoff(pasteboardChangeCount: 7, clickedAt: click) }

    private func decide(
        _ phase: TunnelPhase, hasURL: Bool = true, changeCount: Int = 7, after seconds: Double = 3
    ) -> ShareLinkHandoff.Decision {
        handoff.decide(
            phase: phase, hasURL: hasURL, pasteboardChangeCount: changeCount, now: click + .seconds(seconds))
    }

    @Test func copiesWhenReadyInsideWindowWithUnchangedPasteboard() {
        #expect(decide(.ready) == .copy)
        #expect(decide(.ready, after: 0) == .copy)
        #expect(decide(.ready, after: 15) == .copy)
    }

    @Test func offersWhenPasteboardChanged() {
        #expect(decide(.ready, changeCount: 8) == .offer)
        #expect(decide(.ready, changeCount: 8, after: 0) == .offer)
    }

    @Test func offersWhenReadyAfterWindow() {
        #expect(ShareLinkHandoff.window == .seconds(15))
        #expect(decide(.ready, after: 15.1) == .offer)
        #expect(decide(.ready, after: 3600) == .offer)
    }

    @Test func waitsWhileStartingOrReconnecting() {
        for phase in [TunnelPhase.starting, .reconnecting, .stopping] {
            #expect(decide(phase) == .wait)
            #expect(decide(phase, hasURL: false) == .wait)
            // A slow start must not use up the copy before the link exists.
            #expect(decide(phase, after: 60) == .wait)
        }
    }

    @Test func waitsWhenReadyWithoutURL() {
        #expect(decide(.ready, hasURL: false) == .wait)
        #expect(decide(.ready, hasURL: false, changeCount: 8, after: 60) == .wait)
    }

    @Test func discardsWhenStoppedOrFailed() {
        for phase in [TunnelPhase.stopped, .failed] {
            #expect(decide(phase) == .discard)
            #expect(decide(phase, hasURL: false, changeCount: 8, after: 60) == .discard)
        }
    }
}
