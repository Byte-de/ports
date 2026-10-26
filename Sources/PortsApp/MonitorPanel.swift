import AppKit
import PortsCore
import SwiftUI

struct MonitorWindow: View {
    @Bindable var model: MonitorModel
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Group {
            if let session = model.onboardingSession {
                OnboardingView(model: model).id(session)
            } else {
                MonitorPanel(model: model, surface: .window)
            }
        }
        .padding(12)
        .background(FloatingWindowStyle())
        .background(PanelWindowRegistration(surface: .window, model: model))
        .fixedSize()
        .ignoresSafeArea(.container, edges: .top)
        .task {
            model.revealWindow = {
                guard PanelWindowCoordinator.shared.prepareMainWindow() else { return }
                openWindow(id: "monitor")
                NSApp.activate(ignoringOtherApps: true)
            }
            model.startMonitoring()
            PanelWindowCoordinator.shared.configureNotch(model: model)
        }
        .onChange(of: model.onboardingSession) { _, _ in
            PanelWindowCoordinator.shared.configureNotch(model: model)
        }
    }
}

/// The same panel is used on every surface so navigation and actions stay familiar.
struct MonitorPanel: View {
    @Bindable var model: MonitorModel
    let surface: MonitorSurface
    var collapse: (() -> Void)?
    var drawsSurface = true
    var contentIsRevealed = true
    var revealAnimation: Animation?
    @State private var showingSearch = false
    @FocusState private var searchFocused: Bool
    private var accessibility = PanelAccessibility()

    init(
        model: MonitorModel, surface: MonitorSurface, collapse: (() -> Void)? = nil,
        drawsSurface: Bool = true, contentIsRevealed: Bool = true, revealAnimation: Animation? = nil
    ) {
        self.model = model
        self.surface = surface
        self.collapse = collapse
        self.drawsSurface = drawsSurface
        self.contentIsRevealed = contentIsRevealed
        self.revealAnimation = revealAnimation
    }

    private enum DialogIdentity: Hashable {
        case panel, launch, share
        case process(UUID)
        case job(UUID)
    }
    private var dialogIdentity: DialogIdentity {
        guard model.presentationSurface == surface else { return .panel }
        if model.showLaunchForm { return .launch }
        if model.pendingShare != nil { return .share }
        if let pending = model.pendingAction { return .process(pending.id) }
        if let job = model.pendingJobStop { return .job(job.id) }
        return .panel
    }

    private var isServiceSection: Bool { [.overview, .agents, .servers].contains(model.section) }
    private var page: PanelPage { PanelPage(section: model.section, mode: model.displayMode) }
    private var isDrilledIn: Bool { model.showingDetails || (model.section == .actions && model.showingLogs) }
    private var title: String {
        if model.showingDetails { return model.selected?.title ?? "Prozess beendet" }
        if model.section == .actions && model.showingLogs { return "Ausgabe" }
        return model.displayMode == .board && isServiceSection ? "Board" : model.section.title
    }
    private var contentHeight: CGFloat {
        if isDrilledIn { return 316 }
        if model.section == .settings { return 398 }
        if !isServiceSection { return 284 }
        if model.displayMode == .board { return 284 }
        let rowsHeight = model.filteredServices.reduce(CGFloat(8)) {
            $0 + DS.rowHeight + CGFloat(model.visibleTunnels(for: $1).count) * 48
        }
        return min(320, max(168, rowsHeight))
    }

    var body: some View {
        ZStack {
            dialogContent.id(dialogIdentity)
                .transition(accessibility.reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.98)))
        }
        .animation(
            model.dialogUsesMotion
                ? PanelMotion.fade(accessibility.reduceMotion ? 0.10 : (dialogIdentity == .panel ? 0.12 : 0.18)) : nil,
            value: dialogIdentity
        )
        .foregroundStyle(DS.text).preferredColorScheme(.dark)
        .panelAlert(
            title: "Aktion nicht möglich",
            message: model.presentationSurface == surface ? model.errorMessage : nil
        ) {
            HStack {
                Spacer()
                Button("OK") { model.errorMessage = nil }.buttonStyle(AccentButton())
                    .keyboardShortcut(.defaultAction).onExitCommand { model.errorMessage = nil }
            }
        }
        .background {
            Button("") { revealSearch() }.keyboardShortcut("f").hidden()
                .disabled(model.hasPanelDialog)
        }
        .onChange(of: model.section) { _, _ in showingSearch = false }
        .task { model.startMonitoring() }
    }

    @ViewBuilder private var dialogContent: some View {
        if model.presentationSurface == surface, model.showLaunchForm {
            LaunchForm(model: model) { model.dismissPanelDialog() }
        } else if model.presentationSurface == surface, let target = model.pendingShare {
            PublicShareConfirmation(model: model, target: target)
        } else if model.presentationSurface == surface, let pending = model.pendingAction {
            StopConfirmation(model: model, pending: pending) { model.dismissPanelDialog() }
        } else if model.presentationSurface == surface, let job = model.pendingJobStop {
            JobStopConfirmation(model: model, job: job)
        } else {
            panelContent
        }
    }

    private var panelContent: some View {
        VStack(spacing: DS.navigationSpacing) {
            VStack(spacing: 0) {
                header
                if model.demoMode { demoNotice }
                if showingSearch && !isDrilledIn { searchField }
                if let warning = model.snapshot.warning, !model.demoMode {
                    Label(warning, systemImage: "exclamationmark.triangle")
                        .font(.system(size: 10)).foregroundStyle(DS.orange).lineLimit(2)
                        .padding(.horizontal, 16).padding(.bottom, 8)
                }
                Rectangle().fill(DS.line).frame(height: 0.5).padding(.horizontal, 16)
                content.modifier(AnimatedPanelHeight(height: contentHeight))
                    .animation(
                        model.navigationUsesMotion && model.presentationSurface == surface
                            && !accessibility.reduceMotion
                            ? PanelMotion.resize : nil,
                        value: page)
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
            navigation.zIndex(1)
        }
    }

    private var header: some View {
        HStack(spacing: 0) {
            if isDrilledIn || model.section == .settings || model.section == .activity {
                IconButton(symbol: "chevron.left", help: "Zurück") {
                    if model.showingDetails {
                        model.showingDetails = false
                    } else if model.showingLogs {
                        model.showingLogs = false
                    } else {
                        model.navigate(.servers)
                    }
                }.padding(.leading, -9)
            }
            Text(title).font(.system(size: 14, weight: .medium)).lineLimit(1)
            if !model.isMonitoring && !model.demoMode {
                Image(systemName: "pause.circle").font(.system(size: 11)).foregroundStyle(DS.orange)
                    .padding(.leading, 6).help("Automatische Erkennung pausiert")
            }
            Spacer(minLength: 6)
            if !isDrilledIn && isServiceSection {
                IconButton(symbol: "arrow.clockwise", help: "Aktualisieren (⌘R)") { Task { await model.refresh() } }
                    .disabled(model.isScanning || model.demoMode)
                HStack(spacing: 12) {
                    Label("\(model.agents.count)", systemImage: "sparkles")
                    Label("\(model.servers.count)", systemImage: "server.rack")
                }
                .font(.system(size: 11, design: .monospaced)).foregroundStyle(DS.muted)
                .monospacedDigit().help("\(model.agents.count) Agenten · \(model.servers.count) Dev-Server")
                .padding(.horizontal, 8)
                Spacer(minLength: 0)
            }
            if model.section == .actions && !model.showingLogs {
                IconButton(symbol: "plus", help: "Dienst starten (⌘N)") { presentLaunch() }.disabled(model.demoMode)
            } else if !isDrilledIn && model.section != .settings {
                IconButton(symbol: "magnifyingglass", help: "Suchen (⌘F)", selected: showingSearch) {
                    if showingSearch {
                        showingSearch = false
                        model.search = ""
                    } else {
                        revealSearch()
                    }
                }
            }
            if let collapse {
                IconButton(symbol: "chevron.up", help: "Panel einklappen", action: collapse)
            }
            if model.section != .settings {
                IconButton(symbol: "gearshape", help: "Einstellungen (⌘,)") {
                    model.presentationSurface = surface
                    model.navigate(.settings)
                }
            }
        }.padding(.horizontal, 16).frame(height: 54)
    }

    @ViewBuilder private var content: some View {
        if model.showingDetails {
            InspectorView(model: model, surface: surface)
        } else {
            DirectionalStage(
                selection: page,
                animated: model.navigationUsesMotion && model.presentationSurface == surface,
                order: { $0.rawValue }, distance: 12, duration: 0.15,
                content: { page in
                    switch page {
                    case .overview, .agents, .servers, .board: serviceList(page)
                    case .projects: ProjectsView(model: model, services: model.filteredServices(in: .projects))
                    case .actions: ActionsView(model: model, surface: surface)
                    case .activity: ActivityView(model: model)
                    case .settings: PreferencesView(model: model)
                    }
                }
            )
        }
    }

    @ViewBuilder private func serviceList(_ page: PanelPage) -> some View {
        let services = model.filteredServices(in: page.section)
        if !model.hasScanned {
            VStack(spacing: 12) {
                ProgressView().controlSize(.small)
                Text("Prozesse werden erfasst…").font(.system(size: 11)).foregroundStyle(DS.muted)
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if services.isEmpty {
            EmptyState(
                symbol: model.search.isEmpty ? page.section.symbol : "magnifyingglass",
                title: model.search.isEmpty
                    ? "Keine aktiven \(page == .agents ? "Agenten" : "Dienste")" : "Keine Treffer",
                detail: model.search.isEmpty
                    ? "Laufende Agenten und Dev-Server erscheinen automatisch hier."
                    : "Suche nach Projekt, Agent, PID oder Port.")
        } else if page == .board {
            ServiceBoard(model: model, services: services)
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(services) { service in
                        ServiceRow(model: model, service: service, surface: surface)
                        if service.id != services.last?.id {
                            Rectangle().fill(DS.line).frame(height: 0.5)
                        }
                    }
                }.padding(.horizontal, 16)
            }.scrollIndicators(.hidden)
        }
    }

    private var navigation: some View {
        HStack(spacing: 0) {
            ForEach([NavigationSection.servers, .projects, .actions, .overview, .agents]) { section in
                IconButton(
                    symbol: section.symbol, help: section.title,
                    selected: model.section == section && model.displayMode == .list && !model.showingDetails,
                    immediateHelp: true, systemForeground: true
                ) {
                    model.navigate(section)
                }
            }
            IconButton(
                symbol: "rectangle.split.2x1", help: "Board",
                selected: model.displayMode == .board && isServiceSection && !model.showingDetails,
                immediateHelp: true, systemForeground: true
            ) {
                model.navigate(.overview, mode: .board)
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
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(DS.muted)
            TextField("Projekt, Agent, PID oder Port", text: $model.search)
                .textFieldStyle(.plain).focused($searchFocused)
                .accessibilityLabel("Nach Projekt, Agent, PID oder Port suchen")
                .onExitCommand {
                    model.search = ""
                    showingSearch = false
                }
            Button {
                model.search = ""
                showingSearch = false
            } label: {
                Image(systemName: "xmark.circle.fill").foregroundStyle(DS.muted)
            }.buttonStyle(.plain).help("Suche schließen")
        }.font(.system(size: 12)).padding(.horizontal, 12).frame(height: 36)
            .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
            .padding(.horizontal, 16).padding(.bottom, 10)
    }

    private func revealSearch() {
        if model.section == .settings || model.showingLogs { model.navigate(.overview) }
        model.showingDetails = false
        showingSearch = true
        searchFocused = true
    }
    private func presentLaunch() {
        model.presentLaunch(from: surface)
    }
}
