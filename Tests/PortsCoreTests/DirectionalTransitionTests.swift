import Testing

@testable import PortsCore

struct DirectionalTransitionTests {
    @Test func forwardAndBackwardUseOppositeEntryAndExitDirections() {
        var state = DirectionalTransitionState(2)
        state.select(3, forward: true, animated: true, exitFraction: 0.5)
        #expect(state.layers.last?.entryDirection == 1)
        #expect(state.layers.first?.position == -0.5)
        #expect(state.layers.first?.opacity == 0)
        #expect(state.layers.last?.position == 0)
        #expect(state.layers.last?.opacity == 1)
        state.complete(revision: state.revision)

        state.select(2, forward: false, animated: true, exitFraction: 0.5)
        #expect(state.layers.last?.entryDirection == -1)
        #expect(state.layers.first?.position == 0.5)
        #expect(state.layers.first?.opacity == 0)
        #expect(state.layers.last?.position == 0)
        #expect(state.layers.last?.opacity == 1)
    }

    @Test func rapidReversalReusesMountedPagesAndRejectsStaleCompletion() {
        var state = DirectionalTransitionState("server")
        state.select("agents", forward: true, animated: true, exitFraction: 1)
        let first = state.revision
        state.select("server", forward: false, animated: true, exitFraction: 1)
        #expect(state.layers.map(\.id) == ["server", "agents"])
        #expect(state.layers.first?.position == 0)
        #expect(state.layers.first?.entryDirection == 0)
        // An in-flight insertion keeps its original direction when retargeted.
        #expect(state.layers.last?.entryDirection == 1)
        #expect(state.layers.last?.position == 1)
        let staleCompletion = state.complete(revision: first)
        #expect(!staleCompletion)
        #expect(state.layers.count == 2)
    }

    @Test func keyboardHandoffInvalidatesPendingCompletion() {
        var state = DirectionalTransitionState(0)
        state.select(1, forward: true, animated: true, exitFraction: 1)
        let first = state.revision
        state.select(2, forward: true, animated: false, exitFraction: 1)
        let staleCompletion = state.complete(revision: first)
        #expect(!staleCompletion)
        #expect(state.layers.count == 1)
        #expect(state.layers.first?.id == 2)
        #expect(state.layers.first?.position == 0)
        #expect(state.layers.first?.entryDirection == 0)
        #expect(state.layers.first?.opacity == 1)
    }

    @Test func interruptedSequenceReleasesEveryDepartingPage() {
        var state = DirectionalTransitionState(0)
        for page in 1...5 {
            state.select(page, forward: true, animated: true, exitFraction: 1)
        }
        state.complete(revision: state.revision)
        #expect(state.layers.count == 1)
        #expect(state.layers.first?.id == 5)
        #expect(state.selection == 5)
    }

    @Test func initialPageIsImmediatelyVisibleWithoutAnEntrance() {
        let state = DirectionalTransitionState(2)
        #expect(state.layers.count == 1)
        #expect(state.layers.first?.position == 0)
        #expect(state.layers.first?.entryDirection == 0)
        #expect(state.layers.first?.opacity == 1)
    }
}
