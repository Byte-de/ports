import CoreGraphics
import Foundation
import Testing

@testable import PortsCore

struct PanelResizeTransitionTests {
    private let compact = CGSize(width: 272, height: 44)
    private let expanded = CGSize(width: 500, height: 400)

    @Test func interruptedCollapseCannotClipANewerExpansion() {
        var state = PanelResizeTransition(size: expanded)
        let closing = state.begin(to: compact, animated: true)
        #expect(state.canvas == expanded)
        let reopening = state.begin(to: expanded, animated: true)
        let staleCompletion = state.complete(closing)
        #expect(!staleCompletion)
        #expect(state.canvas == expanded)
        #expect(state.isAnimating)
        let latestCompletion = state.complete(reopening)
        #expect(latestCompletion)
        #expect(!state.isAnimating)
    }

    @Test func latestCollapseReleasesTheTransparentWindowArea() {
        var state = PanelResizeTransition(size: compact)
        let opening = state.begin(to: expanded, animated: true)
        let closing = state.begin(to: compact, animated: true)
        let staleCompletion = state.complete(opening)
        #expect(!staleCompletion)
        #expect(state.canvas == expanded)
        let latestCompletion = state.complete(closing)
        #expect(latestCompletion)
        #expect(state.canvas == compact)
    }

    @Test func immediateHandoffInvalidatesPendingAnimationCompletions() {
        var state = PanelResizeTransition(size: compact)
        let opening = state.begin(to: expanded, animated: true)
        state.begin(to: compact, animated: false)
        let staleCompletion = state.complete(opening)
        #expect(!staleCompletion)
        #expect(state.canvas == compact)
        #expect(!state.isAnimating)
    }

    @Test func changingContentPreservesBothDimensionsUntilCompletion() {
        var state = PanelResizeTransition(size: expanded)
        let taller = CGSize(width: 480, height: 560)
        let transition = state.begin(to: taller, animated: true)
        #expect(state.canvas == CGSize(width: 500, height: 560))
        let completion = state.complete(transition)
        #expect(completion)
        #expect(state.canvas == taller)
    }
}
