import AppKit
import Observation
import PortsCore
import PortsFeatures
import SwiftUI

@MainActor
private final class NotchPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor @Observable
private final class NotchState {
    var expanded = false
    /// The morphing surface: the compact element, or the expanded canvas from the screen top.
    var size = CGSize.zero
    var expandedSize = CGSize(width: DS.panelWidth + 2 * DS.notchInset, height: 400)
    var animatesContent = false
    /// The notch, the notch with its ears, the plain pill or the hot zone the pill rests as.
    var compactSize = CGSize.zero
    /// The expanded content starts below the menu bar.
    var topInset: CGFloat = 0
    /// Nil on a screen without a notch, which shows the plain pill.
    var notchWidth: CGFloat?
    var revealed = false
}

@MainActor
final class NotchController: NSObject {
    static let shared = NotchController()
    /// A pointer passing along the menu bar must not open the ears over the items beside the notch.
    private static let hoverDelay = Duration.milliseconds(200)
    /// Without `.fullScreenAuxiliary` the compact element stays off full-screen Spaces, where it would cover the app.
    /// The expanded panel was asked for, so it may open there.
    private static let compactBehavior: NSWindow.CollectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
    private var panel: NSPanel?
    private weak var model: MonitorModel?
    private let state = NotchState()
    private var resize = PanelResizeTransition(size: .zero)
    private var isEnabled = false
    private var screen: NotchScreen?
    private var hovering = false
    private var focused = false
    private var hoverTask: Task<Void, Never>?

    override init() {
        super.init()
        NotificationCenter.default.addObserver(
            self, selector: #selector(screenChanged), name: NSApplication.didChangeScreenParametersNotification,
            object: nil)
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
            NotificationCenter.default.addObserver(self, selector: #selector(keyChanged), name: name, object: nil)
        }
        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(
            self, selector: #selector(screenChanged), name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        workspace.addObserver(
            self, selector: #selector(accessibilityChanged),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
    }

    func update(model: MonitorModel, expanded: Bool, animated: Bool = false) {
        self.model = model
        isEnabled = model.preferences.showNotch && model.onboardingSession == nil
        guard isEnabled else {
            endHover()
            transition(expanded: false, animated: false)
            return
        }
        if panel == nil { createPanel(model: model) }
        if state.expanded != expanded {
            transition(expanded: expanded, animated: animated)
        }
        // A main-window handoff must finish an in-flight collapse immediately.
        else if !animated && resize.isAnimating {
            transition(expanded: expanded, animated: false)
        } else {
            position(size: resize.canvas, expanded: expanded)
        }
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
        panel.collectionBehavior = Self.compactBehavior
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        let hosting = NSHostingView(
            rootView: NotchView(
                model: model, state: state,
                resized: { [weak self] size in self?.contentResized(size) },
                focusChanged: { [weak self] focused in self?.focusChanged(focused) },
                sharingChanged: { [weak self] in self?.compactChanged(animated: false) }
            ))
        hosting.sizingOptions = []
        // Tracked in AppKit: the pointer reaches the notch while another app is active and the panel is not key.
        hosting.addTrackingArea(
            NSTrackingArea(
                rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self,
                userInfo: nil))
        panel.contentView = hosting
        self.panel = panel
        relayout()
    }

    /// The notched screen wherever it is in the arrangement, else the primary one. Never NSScreen.main: it follows
    /// keyboard focus, so the panel would jump between displays.
    private func chosenScreen() -> NotchScreen? {
        NotchLayout.preferredScreen(
            NSScreen.screens.map { screen in
                let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
                return NotchScreen(
                    id: number?.uint32Value ?? 0, frame: screen.frame, visibleFrame: screen.visibleFrame,
                    safeAreaTop: screen.safeAreaInsets.top, auxiliaryTopLeft: screen.auxiliaryTopLeftArea,
                    auxiliaryTopRight: screen.auxiliaryTopRightArea)
            })
    }

    /// Displays, the menu bar and Spaces change underneath the panel, so its geometry is read again each time.
    private func relayout() {
        let screen = chosenScreen()
        if let screen, screen != self.screen {
            let notched = NotchLayout.notch(screen) != nil
            PortsLog.ui.debug(
                "Notch panel on screen \(screen.id, privacy: .public), notched: \(notched, privacy: .public)")
        }
        self.screen = screen
        // The frame may have moved away from the pointer without an exit event.
        if hovering, compactFrame?.contains(NSEvent.mouseLocation) != true { endHover() }
        transition(expanded: state.expanded, animated: false)
    }

    private var hoversOrFocused: Bool { hovering || (focused && panel?.isKeyWindow == true) }
    private var isSharing: Bool { model?.isSharingPublicly == true }

    private var compactFrame: CGRect? {
        screen.flatMap { NotchLayout.compactFrame($0, hovering: hoversOrFocused, sharing: isSharing) }
    }

    /// Only the expanded panel counts as a visible surface; the compact element scans at the background cadence.
    private func transition(expanded: Bool, animated: Bool) {
        model?.setSurface(.notch, visible: expanded)
        // After a collapse the pointer is over the panel's old area, not over the notch.
        if state.expanded && !expanded { endHover() }
        let compactSize = compactFrame?.size ?? .zero
        let topInset = screen.map(NotchLayout.contentOffset) ?? 0
        let notchWidth = screen.flatMap(NotchLayout.notch)?.width
        let revealed = screen.map { NotchLayout.revealsCounts($0, hovering: hoversOrFocused, sharing: isSharing) }
        let target =
            expanded
            ? CGSize(width: state.expandedSize.width, height: topInset + state.expandedSize.height) : compactSize
        let animate = animated && !PanelMotion.reduceMotion && panel?.isVisible == true
        let revision = resize.begin(to: target, animated: animate)
        let behavior = expanded ? Self.compactBehavior.union(.fullScreenAuxiliary) : Self.compactBehavior
        if let panel, panel.collectionBehavior != behavior { panel.collectionBehavior = behavior }
        // Reserve space first. SwiftUI reveals its fixed-size content inside
        // that canvas, rather than stretching text as the window grows.
        position(size: resize.canvas, expanded: expanded)
        state.animatesContent = animate
        let apply = { [state] in
            state.expanded = expanded
            state.size = target
            state.compactSize = compactSize
            state.topInset = topInset
            state.notchWidth = notchWidth
            state.revealed = revealed ?? false
        }
        if animate {
            withAnimation(PanelMotion.settle(expanded ? 0.26 : 0.18), completionCriteria: .removed) {
                apply()
            } completion: { [weak self] in
                Task { @MainActor in
                    guard let self, self.resize.complete(revision) else { return }
                    self.state.animatesContent = false
                    self.position(size: self.resize.canvas, expanded: self.state.expanded)
                }
            }
        } else {
            var transaction = Transaction(animation: nil)
            transaction.disablesAnimations = true
            withTransaction(transaction) { apply() }
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

    /// Top-anchored at the screen top and centred on the notch. A plain screen whose menu bar is hidden has no compact
    /// element; the next relayout shows it again.
    private func position(size: CGSize, expanded: Bool) {
        guard let panel else { return }
        guard isEnabled, let screen, expanded || resize.isAnimating || compactFrame != nil else {
            panel.orderOut(nil)
            return
        }
        panel.setFrame(NotchLayout.frame(screen, size: size), display: true)
        panel.orderFrontRegardless()
    }

    /// Hover, focus and shares change only the compact element; the expanded panel keeps its frame.
    private func compactChanged(animated: Bool) {
        guard isEnabled, !state.expanded else { return }
        transition(expanded: false, animated: animated)
    }

    private func endHover() {
        hoverTask?.cancel()
        hoverTask = nil
        hovering = false
    }

    private func focusChanged(_ focused: Bool) {
        self.focused = focused
        compactChanged(animated: false)
    }

    @objc(mouseEntered:) private func mouseEntered(_ event: NSEvent) {
        hoverTask?.cancel()
        hoverTask = Task { [weak self] in
            try? await Task.sleep(for: Self.hoverDelay)
            guard let self, !Task.isCancelled, !self.hovering else { return }
            self.hovering = true
            self.compactChanged(animated: true)
        }
    }

    @objc(mouseExited:) private func mouseExited(_ event: NSEvent) {
        let wasHovering = hovering
        endHover()
        if wasHovering { compactChanged(animated: true) }
    }

    /// Keyboard focus reveals the counts only while the panel is key, so they never stay up after switching apps.
    @objc private func keyChanged(_ notification: Notification) {
        guard focused, (notification.object as? NSWindow) === panel else { return }
        compactChanged(animated: false)
    }

    @objc private func screenChanged() { relayout() }
    @objc private func accessibilityChanged() {
        if PanelMotion.reduceMotion { transition(expanded: state.expanded, animated: false) }
    }
}

private struct NotchView: View {
    @Bindable var model: MonitorModel
    @Bindable var state: NotchState
    let resized: (CGSize) -> Void
    let focusChanged: (Bool) -> Void
    let sharingChanged: () -> Void
    @FocusState private var compactFocused: Bool
    private var accessibility = PanelAccessibility()

    init(
        model: MonitorModel, state: NotchState, resized: @escaping (CGSize) -> Void,
        focusChanged: @escaping (Bool) -> Void, sharingChanged: @escaping () -> Void
    ) {
        self.model = model
        self.state = state
        self.resized = resized
        self.focusChanged = focusChanged
        self.sharingChanged = sharingChanged
    }

    private static let compactRadius: CGFloat = 10
    /// A fully transparent pixel passes clicks to the menu bar below; this keeps the hot zone hit-testable but unseen.
    private static let hotZoneOpacity = 0.02
    private static let demoLabel = LocalizedStringResource(
        "notch.demo", defaultValue: "Demo", comment: "Accessibility value of the compact notch while demo data shows")

    private var hasDialog: Bool { model.hasBlockingPanelDialog && model.presentationSurface == .notch }
    private var cardHeight: CGFloat {
        max(44, state.expandedSize.height - 2 * DS.notchInset - DS.navigationSpacing - DS.navigationHeight)
    }
    private var surfaceSize: CGSize {
        state.expanded ? CGSize(width: DS.panelWidth, height: cardHeight) : state.compactSize
    }
    private var surfaceRadius: CGFloat { state.expanded ? DS.panelRadius : Self.compactRadius }
    private var surfaceOffset: CGFloat { state.expanded ? state.topInset + DS.notchInset : 0 }

    var body: some View {
        ZStack(alignment: .top) {
            // The card grows out of the compact element, which draws its own black shape.
            PanelGlass(radius: surfaceRadius)
                .frame(width: surfaceSize.width, height: surfaceSize.height)
                .offset(y: surfaceOffset)
                .opacity(hasDialog || !state.expanded ? 0 : 1)
                .allowsHitTesting(false).accessibilityHidden(true)
            MonitorPanel(
                model: model, surface: .notch, surfaceControl: .collapse(toggle),
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
            .padding(.top, state.topInset)
            .transaction { if state.animatesContent { $0.animation = nil } }
            .offset(y: state.expanded || accessibility.reduceMotion ? 0 : -6)
            .mask(alignment: .top) {
                if hasDialog { Rectangle() } else { revealMask }
            }
            .allowsHitTesting(state.expanded).accessibilityHidden(!state.expanded)
            .disabled(!state.expanded)
            compact
                .opacity(state.expanded ? 0 : 1)
                .allowsHitTesting(!state.expanded).accessibilityHidden(state.expanded)
                .disabled(state.expanded)
        }
        .frame(width: state.size.width, height: state.size.height, alignment: .top)
        .clipShape(
            UnevenRoundedRectangle(
                bottomLeadingRadius: state.expanded ? DS.panelRadius : Self.compactRadius,
                bottomTrailingRadius: state.expanded ? DS.panelRadius : Self.compactRadius, style: .continuous)
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .foregroundStyle(DS.text).environment(\.colorScheme, .dark).preferredColorScheme(.dark)
        .onChange(of: model.isSharingPublicly) { _, _ in sharingChanged() }
    }

    /// Match the growing card exactly, so text cannot appear in the gap above
    /// the separate navigation while the outer window canvas expands.
    private var revealMask: some View {
        ZStack(alignment: .top) {
            RoundedRectangle(cornerRadius: surfaceRadius, style: .continuous)
                .frame(width: surfaceSize.width, height: surfaceSize.height)
                .offset(y: surfaceOffset)
            Rectangle().frame(width: DS.panelWidth, height: DS.navigationHeight)
                .offset(y: state.topInset + cardHeight + DS.notchInset + DS.navigationSpacing)
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    /// At rest it is black on the black notch, or an unseen hot zone at the top of a plain screen. The counts show on
    /// hover, keyboard focus and, beside a notch, while sharing.
    private var compact: some View {
        Button(action: toggle) {
            ZStack {
                UnevenRoundedRectangle(
                    bottomLeadingRadius: Self.compactRadius, bottomTrailingRadius: Self.compactRadius,
                    style: .continuous
                )
                .fill(.black.opacity(state.revealed || state.notchWidth != nil ? 1 : Self.hotZoneOpacity))
                if state.revealed { counts.transition(.opacity) }
            }
            .frame(width: state.compactSize.width, height: state.compactSize.height)
            .contentShape(Rectangle())
        }.buttonStyle(.plain)
            .focused($compactFocused)
            .onChange(of: compactFocused) { _, focused in focusChanged(focused) }
            .accessibilityLabel(Text(compactLabel))
            .accessibilityValue(model.demoMode ? Text(Self.demoLabel) : Text(verbatim: ""))
    }

    /// Beside a notch the agents sit in the left ear and the servers in the right; the plain pill reads ✦ n │ ▤ n.
    private var counts: some View {
        Group {
            if let notchWidth = state.notchWidth {
                HStack(spacing: 0) {
                    HStack(spacing: 4) {
                        demoDot
                        Image(systemName: "sparkles")
                        Text(model.counts.agents, format: .number)
                    }.frame(width: NotchLayout.earWidth)
                    Color.clear.frame(width: notchWidth)
                    HStack(spacing: 4) {
                        Image(systemName: "server.rack")
                        Text(model.counts.servers, format: .number)
                        shareGlobe
                    }.frame(width: NotchLayout.earWidth)
                }
            } else {
                HStack(spacing: 6) {
                    demoDot
                    Image(systemName: "sparkles")
                    Text(model.counts.agents, format: .number)
                    Rectangle().fill(DS.line).frame(width: 1, height: 12)
                    Image(systemName: "server.rack")
                    Text(model.counts.servers, format: .number)
                    shareGlobe
                }
            }
        }
        .font(.system(size: 11)).monospacedDigit().lineLimit(1).foregroundStyle(.primary)
        .blur(radius: state.expanded && !accessibility.reduceMotion ? 2 : 0)
    }

    @ViewBuilder private var demoDot: some View {
        if model.demoMode { Circle().fill(DS.orange).frame(width: 5, height: 5) }
    }

    @ViewBuilder private var shareGlobe: some View {
        if model.isSharingPublicly { Image(systemName: "globe").foregroundStyle(DS.accent) }
    }

    private var compactLabel: LocalizedStringResource {
        model.isSharingPublicly ? "Open \(AppInfo.name), public share active" : "Open \(AppInfo.name)"
    }

    private func toggle() { PanelWindowCoordinator.shared.toggleNotch() }
}
