import AppKit
import Observation
import PortsCore
import SwiftUI

@MainActor
private final class NotchPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor @Observable
private final class NotchState {
    static let compactSize = CGSize(width: 272, height: 44)
    var expanded = false
    var size = compactSize
    var expandedSize = CGSize(width: DS.panelWidth + 2 * DS.notchInset, height: 400)
    var animatesContent = false
}

@MainActor
final class NotchController: NSObject {
    static let shared = NotchController()
    private var panel: NSPanel?
    private weak var model: MonitorModel?
    private let state = NotchState()
    private var resize = PanelResizeTransition(size: NotchState.compactSize)

    override init() {
        super.init()
        NotificationCenter.default.addObserver(
            self, selector: #selector(screenChanged), name: NSApplication.didChangeScreenParametersNotification,
            object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(accessibilityChanged),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
    }

    func update(model: MonitorModel, expanded: Bool, animated: Bool = false) {
        self.model = model
        guard model.preferences.showNotch, model.onboardingSession == nil else {
            transition(expanded: false, animated: false)
            panel?.orderOut(nil)
            return
        }
        if panel == nil { createPanel(model: model) }
        if state.expanded != expanded {
            transition(expanded: expanded, animated: animated)
        }
        // A main-window handoff must finish an in-flight collapse immediately.
        else if !animated && resize.isAnimating {
            transition(expanded: expanded, animated: false)
        }
        panel?.orderFrontRegardless()
        if expanded { panel?.makeKeyAndOrderFront(nil) }
    }

    func raise() { panel?.makeKeyAndOrderFront(nil) }

    private func createPanel(model: MonitorModel) {
        let panel = NotchPanel(
            contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = "Byte Ports – Notch"
        // A custom NSPanel does not reliably inherit a SwiftUI presentation's
        // preferred color scheme. Match the app's deliberately dark surfaces.
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        let hosting = NSHostingView(
            rootView: NotchView(
                model: model, state: state,
                resized: { [weak self] size in self?.contentResized(size) }
            ))
        hosting.sizingOptions = []
        panel.contentView = hosting
        self.panel = panel
        position(size: NotchState.compactSize)
    }

    /// Only the expanded panel counts as a visible surface; the compact pill scans at the background cadence.
    private func transition(expanded: Bool, animated: Bool) {
        model?.setSurface(.notch, visible: expanded)
        let target = expanded ? state.expandedSize : NotchState.compactSize
        let animate = animated && !PanelMotion.reduceMotion && panel?.isVisible == true
        let revision = resize.begin(to: target, animated: animate)
        // Reserve space first. SwiftUI reveals its fixed-size content inside
        // that canvas, rather than stretching text as the window grows.
        position(size: resize.canvas)
        state.animatesContent = animate
        if animate {
            withAnimation(PanelMotion.settle(expanded ? 0.26 : 0.18), completionCriteria: .removed) {
                state.expanded = expanded
                state.size = target
            } completion: { [weak self] in
                Task { @MainActor in
                    guard let self, self.resize.complete(revision) else { return }
                    self.state.animatesContent = false
                    self.position(size: self.resize.canvas)
                }
            }
        } else {
            var transaction = Transaction(animation: nil)
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                state.expanded = expanded
                state.size = target
            }
        }
    }

    private func contentResized(_ size: CGSize) {
        guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0,
            state.expandedSize != size
        else { return }
        state.expandedSize = size
        guard state.expanded else { return }
        // Local content transitions already report their intermediate heights.
        // Follow those measurements, without starting a second window spring.
        transition(expanded: true, animated: resize.isAnimating)
    }

    private func position(size: CGSize) {
        guard let panel, let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let offset = max(screen.safeAreaInsets.top, screen.frame.maxY - screen.visibleFrame.maxY)
        panel.setFrame(
            NSRect(
                x: screen.frame.midX - size.width / 2, y: screen.frame.maxY - offset - size.height - 3,
                width: size.width, height: size.height), display: true)
    }

    @objc private func screenChanged() { transition(expanded: state.expanded, animated: false) }
    @objc private func accessibilityChanged() {
        if PanelMotion.reduceMotion { transition(expanded: state.expanded, animated: false) }
    }
}

private struct NotchView: View {
    @Bindable var model: MonitorModel
    @Bindable var state: NotchState
    let resized: (CGSize) -> Void
    private var accessibility = PanelAccessibility()

    init(model: MonitorModel, state: NotchState, resized: @escaping (CGSize) -> Void) {
        self.model = model
        self.state = state
        self.resized = resized
    }

    private var hasDialog: Bool { model.hasBlockingPanelDialog && model.presentationSurface == .notch }
    private var cardHeight: CGFloat {
        max(44, state.expandedSize.height - 2 * DS.notchInset - DS.navigationSpacing - DS.navigationHeight)
    }
    private var surfaceSize: CGSize {
        state.expanded ? CGSize(width: DS.panelWidth, height: cardHeight) : NotchState.compactSize
    }
    private var surfaceRadius: CGFloat { state.expanded ? DS.panelRadius : 18 }
    private var surfaceOffset: CGFloat { state.expanded ? DS.notchInset : 0 }

    var body: some View {
        ZStack(alignment: .top) {
            PanelGlass(radius: surfaceRadius)
                .frame(width: surfaceSize.width, height: surfaceSize.height)
                .offset(y: surfaceOffset)
                .opacity(hasDialog ? 0 : 1)
                .allowsHitTesting(false).accessibilityHidden(true)
            MonitorPanel(
                model: model, surface: .notch, collapse: toggle,
                drawsSurface: false, contentIsRevealed: state.expanded,
                revealAnimation: state.animatesContent ? PanelMotion.fade(state.expanded ? 0.16 : 0.12) : nil
            )
            .padding(DS.notchInset).fixedSize()
            .background {
                GeometryReader { geometry in
                    Color.clear.onAppear { resized(geometry.size) }
                        .onChange(of: geometry.size) { _, size in resized(size) }
                }
            }
            .transaction { if state.animatesContent { $0.animation = nil } }
            .offset(y: state.expanded || accessibility.reduceMotion ? 0 : -6)
            .mask(alignment: .top) {
                if hasDialog { Rectangle() } else { revealMask }
            }
            .allowsHitTesting(state.expanded).accessibilityHidden(!state.expanded)
            .disabled(!state.expanded)
            compact
                .opacity(state.expanded ? 0 : 1)
                .offset(y: state.expanded && !accessibility.reduceMotion ? 6 : 0)
                .allowsHitTesting(!state.expanded).accessibilityHidden(state.expanded)
                .disabled(state.expanded)
        }
        .frame(width: state.size.width, height: state.size.height, alignment: .top)
        .clipShape(RoundedRectangle(cornerRadius: state.expanded ? 28 : 18, style: .continuous))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .foregroundStyle(DS.text).environment(\.colorScheme, .dark).preferredColorScheme(.dark)
    }

    /// Match the growing card exactly, so text cannot appear in the gap above
    /// the separate navigation while the outer window canvas expands.
    private var revealMask: some View {
        ZStack(alignment: .top) {
            RoundedRectangle(cornerRadius: surfaceRadius, style: .continuous)
                .frame(width: surfaceSize.width, height: surfaceSize.height)
                .offset(y: surfaceOffset)
            Rectangle().frame(width: DS.panelWidth, height: DS.navigationHeight)
                .offset(y: cardHeight + DS.notchInset + DS.navigationSpacing)
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var compact: some View {
        Button(action: toggle) {
            HStack(spacing: 12) {
                Image(systemName: "sparkles")
                Text(model.counts.agents, format: .number)
                Rectangle().fill(DS.line).frame(width: 1, height: 12)
                Image(systemName: "server.rack")
                Text(model.counts.servers, format: .number)
                if model.isSharingPublicly {
                    Rectangle().fill(DS.line).frame(width: 1, height: 12)
                    Image(systemName: "globe").foregroundStyle(DS.accent)
                }
                Spacer()
                if model.demoMode { Text("DEMO").font(.system(size: 8)).foregroundStyle(DS.orange) }
                Image(systemName: "chevron.down").font(.system(size: 9)).foregroundStyle(.secondary)
            }.font(.system(size: 11)).monospacedDigit().foregroundStyle(.primary)
                .padding(.horizontal, 20).frame(width: 272, height: 44).contentShape(Rectangle())
                .blur(radius: state.expanded && !accessibility.reduceMotion ? 2 : 0)
        }.buttonStyle(.plain)
            .accessibilityLabel(Text(compactLabel))
    }

    private var compactLabel: LocalizedStringResource {
        model.isSharingPublicly ? "Open \(AppInfo.name), public share active" : "Open \(AppInfo.name)"
    }

    private func toggle() { PanelWindowCoordinator.shared.toggleNotch() }
}
