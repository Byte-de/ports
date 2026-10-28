import PortsCore
import PortsFeatures
import SwiftUI

/// The content of MainPanelController's window, which sizes itself to it.
struct MonitorWindow: View {
    @Bindable var model: MonitorModel
    var body: some View {
        Group {
            if let session = model.onboardingSession {
                OnboardingView(model: model).id(session)
            } else {
                MonitorPanel(
                    model: model, surface: .window,
                    surfaceControl: .close { PanelWindowCoordinator.shared.closeWindow() })
            }
        }
        .padding(12)
        .fixedSize()
        .ignoresSafeArea(.container, edges: .top)
        .onChange(of: model.onboardingSession) { _, _ in
            PanelWindowCoordinator.shared.configureNotch(model: model)
        }
    }
}

extension PanelTab {
    var title: LocalizedStringResource {
        switch self {
        case .servers: "Servers"
        case .agents: "Agents"
        case .actions: "Actions"
        }
    }

    var symbol: String {
        switch self {
        case .servers: "server.rack"
        case .agents: "sparkles"
        case .actions: "bolt"
        }
    }

    /// Names the tab's shortcut, which PanelShortcuts binds to the same key.
    var help: LocalizedStringResource {
        let key = String(keyEquivalent)
        return switch self {
        case .servers: "Servers (⌘\(key))"
        case .agents: "Agents (⌘\(key))"
        case .actions: "Actions (⌘\(key))"
        }
    }
}

/// One trailing control per surface.
struct PanelSurfaceControl {
    let symbol: String
    let help: LocalizedStringResource
    let action: () -> Void

    /// Hides the window; the status item brings it back at the same position.
    static func close(_ action: @escaping () -> Void) -> Self {
        Self(symbol: "xmark", help: "Close window (⌘W)", action: action)
    }

    static func collapse(_ action: @escaping () -> Void) -> Self {
        Self(symbol: "chevron.up", help: "Collapse panel", action: action)
    }
}

/// The same panel is used on every surface so navigation and actions stay familiar.
struct MonitorPanel: View {
    @Bindable var model: MonitorModel
    let surface: MonitorSurface
    var surfaceControl: PanelSurfaceControl?
    var drawsSurface = true
    var contentIsRevealed = true
    var revealAnimation: Animation?
    /// Each surface searches on its own: typing in one panel never filters another.
    @State private var search = ""
    /// The page the field was opened on, nil while it is closed. Another page never sees the text.
    @State private var searchScope: SearchContext?
    @FocusState private var searchFocused: Bool
    private var accessibility = PanelAccessibility()

    init(
        model: MonitorModel, surface: MonitorSurface, surfaceControl: PanelSurfaceControl? = nil,
        drawsSurface: Bool = true, contentIsRevealed: Bool = true, revealAnimation: Animation? = nil
    ) {
        self.model = model
        self.surface = surface
        self.surfaceControl = surfaceControl
        self.drawsSurface = drawsSurface
        self.contentIsRevealed = contentIsRevealed
        self.revealAnimation = revealAnimation
    }

    private enum DialogIdentity: Hashable {
        case panel, share
        case launch(UUID)
        case deleteAction(UUID)
        case process(UUID)
        case job(UUID)
        case forceStop(UUID)
    }
    private var dialogIdentity: DialogIdentity {
        guard model.presentationSurface == surface else { return .panel }
        if let request = model.launchForm { return .launch(request.id) }
        if let configuration = model.pendingActionDeletion { return .deleteAction(configuration.id) }
        if model.pendingShare != nil { return .share }
        if let pending = model.pendingAction { return .process(pending.id) }
        if let job = model.pendingJobStop { return .job(job.id) }
        if let pending = model.pendingForceStop { return .forceStop(pending.job.id) }
        return .panel
    }

    private var navigation: PanelNavigation { model.navigation }
    private var isServicesRoot: Bool { navigation.isAtRoot && navigation.tab.serviceFilter != nil }
    /// The Servers and Agents roots and the activity page can be searched.
    private var isSearchable: Bool { isServicesRoot || navigation.top == .activity }
    private var movesHere: Bool { model.navigationUsesMotion && model.presentationSurface == surface }

    /// What search filters: the tab's services, or the activity page while it is open over the tab.
    private struct SearchContext: Equatable {
        let tab: PanelTab
        let activity: Bool
    }
    private var searchContext: SearchContext {
        SearchContext(tab: navigation.tab, activity: navigation.stack.contains(.activity))
    }
    /// Pushing details or settings keeps the text for the page underneath; the field returns with it.
    private var showingSearch: Bool { searchScope == searchContext }
    private var query: String { showingSearch ? search : "" }

    private var title: Text {
        switch navigation.top {
        case nil: return Text(navigation.tab.title)
        case .settings: return Text("Settings")
        case .activity: return Text("Activity")
        case .output: return Text("Output")
        case .details(let id):
            guard let service = model.service(for: id) else { return Text("Service ended") }
            return Text(verbatim: service.title)
        }
    }
    /// A failed scan outranks the partial-result warning of the last good one.
    private var scanWarning: Text? {
        guard !model.demoMode else { return nil }
        if let issue = model.detectionIssue { return Text("Detection failed: \(issue)") }
        return model.snapshot.warning.map { Text(verbatim: $0) }
    }
    private func contentHeight(_ visible: [ServiceRecord]?) -> CGFloat {
        switch navigation.top {
        case nil: rootHeight(visible)
        case .settings: 398
        case .activity: 284
        case .details, .output: 316
        }
    }
    /// The tab underneath keeps this height while a page is pushed, so its list doesn't reflow.
    private func rootHeight(_ visible: [ServiceRecord]?) -> CGFloat {
        guard let visible else { return 284 }
        return ServicesPage.height(for: visible, model: model)
    }

    var body: some View {
        // Filtered once per update, so the list and the height it sets agree.
        let visible = navigation.tab.serviceFilter.map { model.visibleServices($0, search: query) }
        ZStack {
            dialogContent(visible).id(dialogIdentity)
                .transition(accessibility.reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.98)))
        }
        .animation(
            model.dialogUsesMotion
                ? PanelMotion.fade(accessibility.reduceMotion ? 0.10 : (dialogIdentity == .panel ? 0.12 : 0.18)) : nil,
            value: dialogIdentity
        )
        .foregroundStyle(DS.text).preferredColorScheme(.dark)
        .panelAlert(
            title: model.panelError?.context.title ?? ErrorContext.generic.title,
            message: model.presentationSurface == surface ? model.panelError?.message : nil
        ) {
            HStack {
                Spacer()
                Button("OK") { model.panelError = nil }.buttonStyle(AccentButton())
                    .keyboardShortcut(.defaultAction).onExitCommand { model.panelError = nil }
            }
        }
        .background {
            PanelShortcuts(model: model, surface: surface, revealSearch: { revealSearch() }, push: { push($0) })
        }
        // Search closes when what it filters changes, when demo and live data swap, and when the notch collapses.
        .onChange(of: searchContext) { _, context in
            if searchScope != context { closeSearch() }
        }
        .onChange(of: model.demoMode) { _, _ in closeSearch() }
        .onChange(of: contentIsRevealed) { _, revealed in
            if !revealed { closeSearch() }
        }
        .task { model.startMonitoring() }
    }

    @ViewBuilder private func dialogContent(_ visible: [ServiceRecord]?) -> some View {
        if model.presentationSurface == surface, let request = model.launchForm {
            LaunchForm(model: model, request: request)
        } else if model.presentationSurface == surface, let configuration = model.pendingActionDeletion {
            ActionDeleteConfirmation(model: model, configuration: configuration)
        } else if model.presentationSurface == surface, let target = model.pendingShare {
            PublicShareConfirmation(model: model, target: target)
        } else if model.presentationSurface == surface, let pending = model.pendingAction {
            StopConfirmation(model: model, pending: pending) { model.dismissPanelDialog() }
        } else if model.presentationSurface == surface, let job = model.pendingJobStop {
            JobStopConfirmation(model: model, job: job)
        } else if model.presentationSurface == surface, let pending = model.pendingForceStop {
            ForceStopConfirmation(model: model, pending: pending)
        } else {
            panelContent(visible)
        }
    }

    private func panelContent(_ visible: [ServiceRecord]?) -> some View {
        VStack(spacing: DS.navigationSpacing) {
            VStack(spacing: 0) {
                header
                if model.demoMode { demoNotice }
                if showingSearch && isSearchable { searchField }
                // Scan problems concern the lists, so other pages stay calm.
                if isServicesRoot, let warning = scanWarning {
                    Label {
                        warning
                    } icon: {
                        Image(systemName: "exclamationmark.triangle")
                    }
                    .font(.system(size: 10)).foregroundStyle(DS.orange).lineLimit(2)
                    .padding(.horizontal, 16).padding(.bottom, 8)
                }
                Rectangle().fill(DS.line).frame(height: 0.5).padding(.horizontal, 16)
                // Only navigation resizes with motion; scans and typing change the height at once.
                content(visible).modifier(AnimatedPanelHeight(height: contentHeight(visible)))
                    .animation(movesHere && !accessibility.reduceMotion ? PanelMotion.resize : nil, value: navigation)
                Spacer().frame(height: 15)
            }
            .blur(radius: contentIsRevealed || accessibility.reduceMotion ? 0 : 2)
            .opacity(contentIsRevealed ? 1 : 0)
            .animation(revealAnimation, value: contentIsRevealed)
            .frame(width: DS.panelWidth)
            .background { if drawsSurface { PanelGlass() } }
            .overlay(alignment: .bottom) {
                ZStack {
                    if let toast = model.toast {
                        Text(toast).font(.system(size: 11)).foregroundStyle(DS.text)
                            .padding(.horizontal, 14).padding(.vertical, 8)
                            .background(DS.surface, in: Capsule()).padding(.bottom, 10)
                            .transition(accessibility.reduceMotion ? .opacity : .opacity.combined(with: .offset(y: 4)))
                    }
                }
                .allowsHitTesting(false)
                .animation(
                    model.toastUsesMotion
                        ? PanelMotion.fade(accessibility.reduceMotion ? 0.10 : (model.toast == nil ? 0.12 : 0.16))
                        : nil,
                    value: model.toast != nil)
            }
            tabBar.zIndex(1)
        }
    }

    private var header: some View {
        HStack(spacing: 0) {
            if !navigation.isAtRoot {
                IconButton(symbol: "chevron.left", help: "Back (⌘[)") { model.goBack() }.padding(.leading, -9)
            }
            title.font(.system(size: 14, weight: .medium)).lineLimit(1)
            if !model.isMonitoring && !model.demoMode {
                PausedBadge { model.setMonitoring(true) }.padding(.leading, 8)
            }
            Spacer(minLength: 6)
            if navigation.isAtRoot && navigation.tab == .actions {
                IconButton(symbol: "plus", help: "New Action (⌘N)") { presentLaunch() }.disabled(model.demoMode)
            } else if isSearchable {
                IconButton(symbol: "magnifyingglass", help: "Search (⌘F)", selected: showingSearch) {
                    if showingSearch { closeSearch() } else { revealSearch() }
                }
            }
            IconButton(symbol: "clock.arrow.circlepath", help: "Activity", selected: navigation.top == .activity) {
                push(.activity)
            }
            settingsButton
            if let surfaceControl {
                IconButton(symbol: surfaceControl.symbol, help: surfaceControl.help, action: surfaceControl.action)
            }
        }.padding(.horizontal, 16).frame(height: 54)
    }

    /// A newer release only adds a small dot: no menu bar change, no notification.
    private var settingsButton: some View {
        let badge = model.showsUpdateBadge
        let help: LocalizedStringResource = badge ? "Settings – update available (⌘,)" : "Settings (⌘,)"
        return IconButton(symbol: "gearshape", help: help, selected: navigation.top == .settings) {
            push(.settings)
        }
        .overlay {
            if badge {
                // At the glyph's top trailing corner; the 14 pt gear sits centred in its 40 pt button.
                Circle().fill(DS.accent).frame(width: 6, height: 6).offset(x: 8, y: -8)
                    .allowsHitTesting(false).accessibilityHidden(true)
            }
        }
    }

    /// Pages are pushed over the tab, which stays mounted underneath with its scroll position.
    private func content(_ visible: [ServiceRecord]?) -> some View {
        PushStage(destination: navigation.top, animated: movesHere) {
            DirectionalStage(
                selection: navigation.tab, animated: movesHere, order: { $0.rawValue }, distance: 12, duration: 0.15
            ) { tab in
                if let filter = tab.serviceFilter {
                    // Search belongs to the tab in front; a departing tab fades out unfiltered.
                    let front = tab == navigation.tab
                    ServicesPage(
                        model: model, surface: surface, filter: filter,
                        services: front ? visible ?? [] : model.visibleServices(filter, search: ""),
                        search: front ? query : "")
                } else {
                    ActionsView(model: model, surface: surface)
                }
            }
            .frame(height: rootHeight(visible), alignment: .top)
        } pushed: { destination in
            switch destination {
            case .settings: PreferencesView(model: model)
            case .activity: ActivityView(model: model, search: query)
            case .details(let id): InspectorView(model: model, serviceID: id, surface: surface)
            case .output(let id): LogPane(model: model, jobID: id, surface: surface)
            }
        }
    }

    /// The tab stays selected while a page is pushed over it; selecting it again pops to its root.
    private var tabBar: some View {
        HStack(spacing: 0) {
            ForEach(PanelTab.allCases, id: \.self) { tab in
                NavigationTabButton(
                    title: tab.title, symbol: tab.symbol, help: tab.help, selected: navigation.tab == tab
                ) {
                    model.select(tab)
                }
            }
        }
        // Keep material separate from content fades. The clipped, nonactivating
        // notch uses AppKit vibrancy: Liquid Glass can lose its backdrop here.
        .opacity(contentIsRevealed ? 1 : 0)
        .animation(revealAnimation, value: contentIsRevealed)
        .padding(4).modifier(ControlGlass(radius: 24, usesLiquidGlass: surface != .notch))
    }

    private var demoNotice: some View {
        HStack(spacing: 5) {
            Text("Demo").font(.system(size: 10, weight: .medium))
                .help("Beispieldaten · Prozessaktionen sind deaktiviert")
            Spacer()
            Button("Live anzeigen") { model.toggleDemo() }.buttonStyle(.plain).font(.system(size: 10))
        }.foregroundStyle(DS.orange).padding(.horizontal, 16).padding(.bottom, 9)
    }

    private var searchField: some View {
        let activity = navigation.top == .activity
        let prompt: LocalizedStringResource = activity ? "Search activity" : "Project, name, PID or port"
        let label: LocalizedStringResource = activity ? "Search activity" : "Search by project, name, PID or port"
        return HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(DS.muted)
            TextField(prompt, text: $search)
                .textFieldStyle(.plain).focused($searchFocused)
                .accessibilityLabel(Text(label))
                .onExitCommand { closeSearch() }
            Button {
                closeSearch()
            } label: {
                Image(systemName: "xmark.circle.fill").foregroundStyle(DS.muted)
            }.buttonStyle(.plain).help("Suche schließen")
        }.font(.system(size: 12)).padding(.horizontal, 12).frame(height: 36)
            .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
            .padding(.horizontal, 16).padding(.bottom, 10)
    }

    /// Searches the page in front when it can be searched, otherwise the services tab underneath or Servers.
    private func revealSearch() {
        if !isSearchable { model.select(navigation.tab.serviceFilter == nil ? .servers : navigation.tab) }
        if !showingSearch {
            search = ""
            searchScope = searchContext
        }
        searchFocused = true
    }

    /// A closed field never leaves text behind that filters invisibly.
    private func closeSearch() {
        searchScope = nil
        search = ""
    }

    private func push(_ destination: PanelDestination) {
        model.presentationSurface = surface
        model.push(destination)
    }
    private func presentLaunch() {
        model.presentLaunch(from: surface)
    }
}

/// The panel's shortcuts act on the surface whose window is key, so ⌘1 switches tabs in the notch without opening the
/// window. They never go into the app's menu commands as well: a key bound twice fires in a different place depending on
/// which window is key. Hidden buttons still take their shortcuts; all of them are inert while a dialog is open.
private struct PanelShortcuts: View {
    let model: MonitorModel
    let surface: MonitorSurface
    let revealSearch: () -> Void
    let push: (PanelDestination) -> Void

    var body: some View {
        let navigation = model.navigation
        Group {
            Group {
                ForEach(PanelTab.allCases, id: \.self) { tab in
                    shortcut(KeyEquivalent(tab.keyEquivalent)) { model.select(tab) }
                }
                shortcut("f", action: revealSearch)
                shortcut("[") { model.goBack() }.disabled(navigation.isAtRoot)
                shortcut(",") { push(.settings) }.disabled(navigation.top == .settings)
                shortcut("n") { model.presentLaunch(from: surface) }.disabled(model.demoMode)
                shortcut("r") { Task { await model.refresh() } }.disabled(model.demoMode)
            }
            .disabled(model.hasPanelDialog)
            // Like the close button: the window hides, the app keeps running and the status item brings it back. It
            // stays enabled under a dialog and does nothing there, because a disabled ⌘W would fall through to
            // File > Close and hide the window with the dialog still open.
            if surface == .window {
                shortcut("w") { if !model.hasPanelDialog { PanelWindowCoordinator.shared.closeWindow() } }
            }
        }
        .hidden()
    }

    private func shortcut(_ key: KeyEquivalent, action: @escaping () -> Void) -> some View {
        Button("", action: action).keyboardShortcut(key)
    }
}

/// Stays in the header on every page while detection is paused, so a pause is never forgotten. A click resumes.
private struct PausedBadge: View {
    let resume: () -> Void

    var body: some View {
        Button(action: resume) {
            HStack(spacing: 4) {
                Image(systemName: "pause.circle.fill")
                Text(
                    LocalizedStringResource(
                        "detection.paused", defaultValue: "Paused", comment: "Header badge while detection is paused"))
            }
            .font(.system(size: 10, weight: .medium)).foregroundStyle(DS.orange)
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(DS.orange.opacity(0.14), in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain).fixedSize()
        .help(Text("Resume detection"))
        .accessibilityLabel(Text("Detection paused"))
    }
}
