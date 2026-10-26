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

/// This order matches the visible navigation, including the separate Board tab.
enum PanelPage: Int, Sendable {
    case servers, projects, actions, overview, agents, board, activity, settings

    init(section: NavigationSection, mode: DisplayMode) {
        if mode == .board && [.overview, .agents, .servers].contains(section) {
            self = .board
        } else {
            switch section {
            case .servers: self = .servers
            case .projects: self = .projects
            case .actions: self = .actions
            case .overview: self = .overview
            case .agents: self = .agents
            case .activity: self = .activity
            case .settings: self = .settings
            }
        }
    }

    var section: NavigationSection {
        switch self {
        case .servers: .servers
        case .projects: .projects
        case .actions: .actions
        case .overview, .board: .overview
        case .agents: .agents
        case .activity: .activity
        case .settings: .settings
        }
    }
}
