import PortsCore
import PortsFeatures
import SwiftUI

/// A click does what the row stands for: opens the server in the browser, brings the app forward, or shows details.
/// The trailing slot shows the uptime until hover or keyboard focus reveals the actions; the chevron always opens
/// details. A share in progress keeps its control in view.
struct ServiceRow: View {
    private enum Control: Hashable {
        case copy, share, stop, details
    }
    /// Also the details page's stop button.
    static let stopLabel = LocalizedStringResource(
        "service.stopEllipsis", defaultValue: "Stop…", comment: "Asks to confirm stopping a detected service")

    @Bindable var model: MonitorModel
    let service: ServiceRecord
    let surface: MonitorSurface
    @State private var hovered = false
    @State private var focusedControls: Set<Control> = []
    @FocusState private var primaryFocused: Bool
    private var accessibility = PanelAccessibility()

    init(model: MonitorModel, service: ServiceRecord, surface: MonitorSurface) {
        self.model = model
        self.service = service
        self.surface = surface
    }

    private var revealed: Bool { hovered || primaryFocused || !focusedControls.isEmpty }
    private var primaryAction: ServicePrimaryAction { model.primaryAction(for: service) }
    private var shareTarget: TunnelTarget? { model.tunnelTarget(service) }
    private var isPaused: Bool { service.process.state == .paused }

    /// An app without a port, such as Claude, has no actions: hover leaves its uptime in place.
    private var hasActions: Bool { service.primaryEndpoint != nil || model.isControllable(service) }

    /// A share being prepared or running stays in view, at the same place as when the actions are revealed.
    private var sharePinned: Bool {
        guard let target = shareTarget else { return false }
        return model.isShareWorking(target) || model.tunnelRecord(target)?.phase == .ready
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                Button {
                    model.performPrimaryAction(service, from: surface)
                } label: {
                    ServiceIdentityLabel(service: service, showsOpenHint: primaryAction != .showDetails)
                        .frame(height: DS.rowHeight).contentShape(Rectangle())
                }
                .buttonStyle(.plain).focused($primaryFocused)
                .help(Text(primaryHint))
                .accessibilityLabel(accessibilityLabel)
                .accessibilityHint(Text(primaryHint))
                .accessibilityActions { namedActions }
                trailingSlot
                IconButton(symbol: "chevron.right", help: "Details", focusChanged: { focus(.details, $0) }) {
                    model.showDetails(service, from: surface)
                }
            }.transaction { $0.animation = nil }
            ForEach(model.visibleTunnels(for: service)) { record in
                TunnelStatusRow(model: model, record: record)
                    .transition(.opacity)
            }
        }
        .background(hovered ? Color.white.opacity(0.025) : .clear)
        .onHover { hovered = $0 }
        .contextMenu { menu }
    }

    /// Fixed width, so revealing the actions never moves the identity. Hidden actions stay in the focus order: tabbing
    /// into one reveals them all.
    private var trailingSlot: some View {
        ZStack(alignment: .trailing) {
            Text(verbatim: Format.uptime(service.id.startDate)).font(.system(size: 11, design: .monospaced))
                .foregroundStyle(DS.muted).monospacedDigit().lineLimit(1).padding(.trailing, 8)
                .opacity((revealed && hasActions) || sharePinned ? 0 : 1).accessibilityHidden(true)
            HStack(spacing: 0) {
                if let endpoint = service.primaryEndpoint {
                    IconButton(symbol: "doc.on.doc", help: copyTitle, focusChanged: { focus(.copy, $0) }) {
                        copyAddress(endpoint)
                    }.reveal(revealed)
                }
                if let target = shareTarget {
                    ShareServerButton(
                        model: model, target: target, surface: surface, focusChanged: { focus(.share, $0) }
                    ).reveal(revealed || sharePinned)
                }
                if model.isControllable(service) {
                    IconButton(
                        symbol: "stop.circle", help: Self.stopLabel, tint: DS.red, focusChanged: { focus(.stop, $0) }
                    ) {
                        requestStop()
                    }
                    .disabled(!model.canControl(service)).reveal(revealed)
                }
            }
        }
        .frame(width: 120, alignment: .trailing)
        .animation(accessibility.reduceMotion ? nil : .easeOut(duration: 0.12), value: revealed)
    }

    private var primaryHint: LocalizedStringResource {
        switch primaryAction {
        case .openURL: "Open in browser"
        case .activate: "Open app"
        case .showDetails: "Show details"
        }
    }

    private var accessibilityLabel: Text {
        let project =
            service.projectDirectory == nil
            ? String(localized: "no project", comment: "Spoken in a service row for a process without a project folder")
            : service.process.projectName
        if isPaused { return Text("\(service.title), \(project), paused") }
        return Text("\(service.title), \(project), running for \(Format.spokenUptime(service.id.startDate))")
    }

    /// HTTP servers copy their URL; databases and other listeners copy host:port, which their clients take.
    private var copyTitle: LocalizedStringResource { model.speaksHTTP(service) ? "Copy URL" : "Copy Address" }

    private func copyAddress(_ endpoint: ListeningEndpoint) {
        if model.speaksHTTP(service), let url = endpoint.url {
            model.copy(url.absoluteString, message: "URL copied")
        } else {
            model.copy(Format.hostAndPort(endpoint), message: "Address copied")
        }
    }

    private func requestStop() {
        model.request(.terminate, service: service, from: surface)
    }

    private func focus(_ control: Control, _ focused: Bool) {
        if focused { focusedControls.insert(control) } else { focusedControls.remove(control) }
    }

    /// The row's controls, for VoiceOver's actions rotor.
    @ViewBuilder private var namedActions: some View {
        Button("Details") { model.showDetails(service, from: surface) }
        if let endpoint = service.primaryEndpoint {
            Button(copyTitle) { copyAddress(endpoint) }
        }
        if let target = shareTarget, model.canShare(target) {
            Button(shareTitle(target)) { model.share(target, from: surface) }
        }
        if model.canControl(service) {
            Button(Self.stopLabel) { requestStop() }
        }
    }

    private func shareTitle(_ target: TunnelTarget) -> LocalizedStringResource {
        model.tunnelRecord(target)?.phase == .ready ? "Copy Share Link" : "Share Publicly"
    }

    /// Items that can't apply to this service are left out rather than disabled.
    @ViewBuilder private var menu: some View {
        switch primaryAction {
        case .openURL: Button("Open in Browser") { model.performPrimaryAction(service, from: surface) }
        case .activate: Button("Open App") { model.performPrimaryAction(service, from: surface) }
        case .showDetails: EmptyView()
        }
        Button("Details") { model.showDetails(service, from: surface) }
        Divider()
        if let endpoint = service.primaryEndpoint {
            Button(copyTitle) { copyAddress(endpoint) }
        }
        Button("Copy Launch Command") { model.copy(service.process.command) }
        if let directory = service.projectDirectory {
            Button("Show in Finder") { model.openDirectory(directory) }.disabled(model.demoMode)
            Button(newActionInFolder) { model.presentLaunch(from: surface, prefill: LaunchDraft(directory: directory)) }
                .disabled(model.demoMode)
        }
        if let target = shareTarget {
            Button(shareTitle(target)) { model.share(target, from: surface) }.disabled(!model.canShare(target))
        }
        if model.isControllable(service) {
            Divider()
            Button(isPaused ? "Resume" : "Pause") {
                model.request(isPaused ? .resume : .pause, service: service, from: surface)
            }.disabled(!model.canControl(service))
            Button(role: .destructive) {
                requestStop()
            } label: {
                Text(Self.stopLabel)
            }.disabled(!model.canControl(service))
        }
    }
}

/// Offered by a service's row and its details wherever the service has a project folder.
private let newActionInFolder: LocalizedStringResource = "New Action in This Folder…"

extension View {
    /// Hover-revealed controls keep their place and their focus order while hidden.
    fileprivate func reveal(_ revealed: Bool) -> some View {
        opacity(revealed ? 1 : 0).allowsHitTesting(revealed)
    }
}

struct InspectorView: View {
    @Bindable var model: MonitorModel
    let serviceID: ProcessIdentity
    let surface: MonitorSurface
    var body: some View {
        if let service = model.service(for: serviceID) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HStack {
                        StatusLabel(state: service.process.state)
                        Spacer()
                        Text("PID \(String(service.id.pid)) · \(Format.uptime(service.id.startDate))")
                            .font(.system(size: 11, design: .monospaced)).foregroundStyle(DS.muted)
                    }
                    HStack(spacing: 24) {
                        Label(Format.cpu(service.cpuPercent), systemImage: "cpu")
                        Label(Format.memory(service.process.residentBytes), systemImage: "memorychip")
                        Spacer()
                        if let history = model.histories[service.id], history.count > 1 {
                            Sparkline(values: history).frame(width: 90, height: 23)
                        }
                    }.font(.system(size: 12, design: .monospaced)).monospacedDigit()
                    if let directory = service.projectDirectory {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("PROJEKTORDNER").overline()
                            HStack(spacing: 8) {
                                Text(Format.path(directory)).font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(DS.muted).textSelection(.enabled).lineLimit(3)
                                Spacer()
                                IconButton(symbol: "folder", help: "Im Finder öffnen") {
                                    model.openDirectory(directory)
                                }
                                .disabled(model.demoMode)
                                IconButton(symbol: "plus", help: newActionInFolder) {
                                    model.presentLaunch(from: surface, prefill: LaunchDraft(directory: directory))
                                }
                                .disabled(model.demoMode)
                            }
                        }
                    }
                    if !service.ports.isEmpty {
                        ServiceAddressSection(model: model, service: service, surface: surface)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("STARTBEFEHL").overline()
                            Spacer()
                            IconButton(symbol: "doc.on.doc", help: "Startbefehl kopieren") {
                                model.copy(service.process.command)
                            }
                        }
                        Text(service.process.command).font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(DS.muted).textSelection(.enabled).lineLimit(8).lineSpacing(3)
                    }
                    // Protected processes and the demo offer no pause or stop; only apps come forward.
                    if model.canActivate(service) || model.isControllable(service) {
                        HStack(spacing: 8) {
                            if model.canActivate(service) {
                                Button {
                                    model.activate(service)
                                } label: {
                                    Label("Open app", systemImage: "arrow.up.forward.square")
                                }.buttonStyle(QuietButton()).disabled(model.demoMode)
                            }
                            Spacer()
                            if model.isControllable(service) {
                                Button {
                                    model.request(
                                        service.process.state == .paused ? .resume : .pause, service: service,
                                        from: surface)
                                } label: {
                                    Label(
                                        service.process.state == .paused ? "Fortsetzen" : "Pausieren",
                                        systemImage: service.process.state == .paused ? "play" : "pause")
                                }.buttonStyle(QuietButton()).disabled(!model.canControl(service))
                                IconButton(symbol: "stop.circle", help: ServiceRow.stopLabel, tint: DS.red) {
                                    model.request(.terminate, service: service, from: surface)
                                }.disabled(!model.canControl(service))
                            }
                        }
                    }
                }.padding(16)
            }
        } else {
            // The back button in the header leads to the list.
            EmptyState(symbol: "checkmark.circle", title: "Service no longer running")
        }
    }
}

struct StopConfirmation: View {
    @Bindable var model: MonitorModel
    let pending: PendingAction
    let dismiss: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Stop “\(pending.service.title)”?").font(.system(size: 17, weight: .medium))
            consequence.font(.system(size: 12)).foregroundStyle(DS.muted).lineSpacing(3)
            HStack {
                Text("PID \(String(pending.service.id.pid))").font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(DS.muted)
                Spacer()
                Button("Cancel") { dismiss() }.buttonStyle(QuietButton()).keyboardShortcut(.cancelAction)
                Button(role: .destructive) {
                    model.perform(pending.action, service: pending.service)
                    dismiss()
                } label: {
                    Text(
                        LocalizedStringResource(
                            "service.stop", defaultValue: "Stop", comment: "Confirms stopping a detected service"))
                }.buttonStyle(QuietButton(tint: DS.red))
            }
        }.padding(24).frame(width: DS.panelWidth).background(PanelGlass())
    }
    /// Agents lose unfinished work; other processes are only asked to quit.
    private var consequence: Text {
        let service = pending.service
        guard service.kind == .agent else {
            return Text("The process will be asked to quit and won't restart automatically.")
        }
        let project = service.projectDirectory == nil ? service.title : service.process.projectName
        return Text("Current work in “\(project)” will be interrupted. The process won't restart automatically.")
    }
}

/// Shared visual identity for live rows and the read-only onboarding preview.
struct ServiceIdentityLabel: View {
    let service: ServiceRecord
    /// An arrow after the title says that a click opens the browser or the app.
    var showsOpenHint = false
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                if let endpoint = service.primaryEndpoint {
                    Text(verbatim: ":\(endpoint.port)").font(.system(size: 14, design: .monospaced))
                    Text(service.title).foregroundStyle(DS.tint(service)).lineLimit(1)
                } else {
                    ServiceIcon(service: service, size: 18)
                    Text(service.title).lineLimit(1)
                }
                if showsOpenHint {
                    Image(systemName: "arrow.up.forward").font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(DS.muted).accessibilityHidden(true)
                }
                if service.process.state == .paused {
                    Image(systemName: "pause.circle").foregroundStyle(DS.orange).font(.system(size: 11))
                }
            }.font(.system(size: 13, weight: .medium))
            HStack(spacing: 6) {
                Image(systemName: location.symbol).font(.system(size: 11)).accessibilityHidden(true)
                location.text.font(.system(size: 11, design: .monospaced)).lineLimit(1).truncationMode(.middle)
            }.foregroundStyle(DS.muted)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private var location: (symbol: String, text: Text) {
        if let directory = service.projectDirectory { return ("folder", Text(verbatim: Format.path(directory))) }
        if service.isDesktopApplication { return ("macwindow", Text("Desktop app")) }
        return ("number", Text("PID \(String(service.id.pid))"))
    }
}
