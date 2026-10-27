import PortsCore
import SwiftUI

/// A bounded deck of stable page identities. No timers, snapshots, or animation
/// on initial display; departing controls stop accepting input immediately.
struct DirectionalStage<Page: Hashable & Sendable, Content: View>: View {
    let selection: Page
    let animated: Bool
    let order: (Page) -> Int
    let distance: CGFloat
    let duration: Double
    var exitFraction: Double = 1
    @ViewBuilder let content: (Page) -> Content
    @State private var state: DirectionalTransitionState<Page>
    private var accessibility = PanelAccessibility()

    init(
        selection: Page, animated: Bool, order: @escaping (Page) -> Int,
        distance: CGFloat, duration: Double, exitFraction: Double = 1,
        @ViewBuilder content: @escaping (Page) -> Content
    ) {
        self.selection = selection
        self.animated = animated
        self.order = order
        self.distance = distance
        self.duration = duration
        self.exitFraction = exitFraction
        self.content = content
        _state = State(initialValue: DirectionalTransitionState(selection))
    }

    var body: some View {
        ZStack {
            ForEach(state.layers) { layer in
                content(layer.id)
                    // Page internals keep their own motion policy. Polling and
                    // text layout must not inherit the deck's animation.
                    .transaction { $0.animation = nil }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .blur(radius: accessibility.reduceMotion ? 0 : 2 * (1 - layer.opacity))
                    .opacity(layer.opacity)
                    .offset(x: accessibility.reduceMotion ? 0 : CGFloat(layer.position) * distance)
                    .animation(
                        PanelMotion.fade(
                            accessibility.reduceMotion ? 0.10 : (layer.id == selection ? duration : 0.12)),
                        value: layer.opacity
                    )
                    .transition(.asymmetric(insertion: insertion(for: layer), removal: .identity))
                    .allowsHitTesting(layer.id == selection)
                    .disabled(layer.id != selection)
                    .accessibilityElement(children: layer.id == selection ? .contain : .ignore)
                    .accessibilityHidden(layer.id != selection)
                    .zIndex(layer.id == selection ? 1 : 0)
            }
        }
        .clipped()
        .onChange(of: selection) { previous, next in
            let forward = order(next) > order(previous)
            guard animated else {
                withoutAnimation { state.select(next, forward: forward, animated: false, exitFraction: exitFraction) }
                return
            }
            let revision = state.revision &+ 1
            withAnimation(
                PanelMotion.fade(accessibility.reduceMotion ? 0.10 : duration), completionCriteria: .removed
            ) {
                state.select(next, forward: forward, animated: true, exitFraction: exitFraction)
            } completion: {
                Task { @MainActor in
                    withoutAnimation { _ = state.complete(revision: revision) }
                }
            }
        }
        .onChange(of: accessibility.reduceMotion) { _, _ in
            withoutAnimation { state.select(selection, forward: true, animated: false, exitFraction: exitFraction) }
        }
    }

    private func insertion(for layer: DirectionalTransitionState<Page>.Layer) -> AnyTransition {
        guard layer.entryDirection != 0 else { return .identity }
        guard !accessibility.reduceMotion else { return .opacity }
        let offset = CGFloat(layer.entryDirection) * distance
        return .modifier(
            active: PageEntrance(progress: 0, offset: offset),
            identity: PageEntrance(progress: 1, offset: offset))
    }

    private func withoutAnimation(_ update: () -> Void) {
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction, update)
    }
}

/// One interpolated phase keeps translation, opacity and blur in sync, even
/// when the page's own transaction intentionally disables inherited animation.
private struct PageEntrance: AnimatableModifier {
    nonisolated var progress: CGFloat
    let offset: CGFloat
    nonisolated var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }
    func body(content: Content) -> some View {
        content
            .blur(radius: 2 * (1 - progress))
            .opacity(progress)
            .offset(x: offset * (1 - progress))
    }
}

/// Pages pushed over a root that stays mounted underneath, so the root keeps its scroll position and state while it
/// is covered. Only the top page is shown; going back reveals the root as it was left.
struct PushStage<Destination: Hashable & Sendable, Root: View, Pushed: View>: View {
    let destination: Destination?
    let animated: Bool
    @ViewBuilder let root: () -> Root
    @ViewBuilder let pushed: (Destination) -> Pushed
    private var accessibility = PanelAccessibility()

    init(
        destination: Destination?, animated: Bool, @ViewBuilder root: @escaping () -> Root,
        @ViewBuilder pushed: @escaping (Destination) -> Pushed
    ) {
        self.destination = destination
        self.animated = animated
        self.root = root
        self.pushed = pushed
    }

    var body: some View {
        let covered = destination != nil
        let travels = !accessibility.reduceMotion
        ZStack(alignment: .top) {
            root()
                .blur(radius: covered && travels ? 2 : 0)
                .opacity(covered ? 0 : 1)
                .offset(x: covered && travels ? -6 : 0)
                .animation(animation(entering: !covered), value: covered)
                .allowsHitTesting(!covered)
                .disabled(covered)
                .accessibilityHidden(covered)
            if let destination {
                pushed(destination)
                    // Polling and text layout inside the page must not inherit the push's animation.
                    .transaction { $0.animation = nil }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .id(destination)
                    .transition(transition)
                    .zIndex(1)
            }
        }
        // The root keeps its own height underneath, so the stage takes the proposed height and clips the rest.
        .frame(minHeight: 0, maxHeight: .infinity, alignment: .top)
        .clipped()
        .animation(animation(entering: covered), value: destination)
    }

    /// A page fades in over 0.15 s and out over 0.12 s. Reduce Motion fades everything over 0.10 s without travel.
    private func animation(entering: Bool) -> Animation? {
        guard animated else { return nil }
        return PanelMotion.fade(accessibility.reduceMotion ? 0.10 : (entering ? 0.15 : 0.12))
    }

    private var transition: AnyTransition {
        guard !accessibility.reduceMotion else { return .opacity }
        return .modifier(
            active: PageEntrance(progress: 0, offset: 12), identity: PageEntrance(progress: 1, offset: 12))
    }
}
