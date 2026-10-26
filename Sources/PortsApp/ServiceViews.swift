import PortsCore
import SwiftUI

struct ServiceRow: View {
    @Bindable var model: MonitorModel
    let service: ServiceRecord
    let surface: MonitorSurface
    @State private var hovered = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                Button {
                    model.inspect(service)
                } label: {
                    ServiceIdentityLabel(service: service).frame(height: DS.rowHeight).contentShape(Rectangle())
                }.buttonStyle(.plain)
                    .help("\(service.title) · Details anzeigen")
                    .accessibilityLabel(
                        service.process.state == .paused
                            ? Text("\(service.title), \(service.process.projectName), pausiert. Details anzeigen")
                            : Text("\(service.title), \(service.process.projectName), läuft. Details anzeigen"))
                Text(Format.uptime(service.id.startDate)).font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(DS.muted).monospacedDigit().lineLimit(1)
                    .padding(.leading, 8).padding(.trailing, 4).help("Laufzeit")
                IconButton(
                    symbol: "arrow.up.forward.square",
                    help: service.primaryEndpoint == nil ? "Im Terminal oder als App öffnen" : "Im Browser öffnen"
                ) {
                    if let endpoint = service.primaryEndpoint {
                        model.openEndpoint(endpoint)
                    } else {
                        model.activate(service)
                    }
                }.disabled(model.demoMode)
                IconButton(symbol: "doc.on.doc", help: service.primaryEndpoint == nil ? "PID kopieren" : "URL kopieren")
                {
                    if let url = service.primaryEndpoint?.url {
                        model.copy(url.absoluteString, message: "URL kopiert")
                    } else {
                        model.copy(String(service.id.pid), message: "PID kopiert")
                    }
                }
                if let target = model.tunnelTarget(service) {
                    ShareServerButton(model: model, target: target, surface: surface)
                }
                IconButton(symbol: "stop.circle", help: "\(service.title) stoppen…", tint: DS.red) {
                    model.request(.terminate, service: service, from: surface)
                }.disabled(!model.canControl(service))
            }.transaction { $0.animation = nil }
            ForEach(model.visibleTunnels(for: service)) { record in
                TunnelStatusRow(model: model, record: record)
                    .transition(.opacity)
            }
        }
        .background(hovered ? Color.white.opacity(0.025) : .clear)
        .onHover { hovered = $0 }
        .contextMenu {
            Button("Details anzeigen") { model.inspect(service) }
            Button(service.process.state == .paused ? "Fortsetzen" : "Pausieren") {
                model.request(service.process.state == .paused ? .resume : .pause, service: service, from: surface)
            }.disabled(!model.canControl(service))
            Button("Startbefehl kopieren") { model.copy(service.process.command) }
            Divider()
            Button("Stoppen…", role: .destructive) { model.request(.terminate, service: service, from: surface) }
                .disabled(!model.canControl(service))
        }
    }
}

struct ServiceBoard: View {
    @Bindable var model: MonitorModel
    let services: [ServiceRecord]
    var body: some View {
        ScrollView {
            HStack(alignment: .top, spacing: 12) {
                column("Läuft", state: .running)
                column("Pausiert", state: .paused)
            }.padding(16)
        }
    }
    private func column(_ title: LocalizedStringResource, state: ProcessState) -> some View {
        let services = services.filter { $0.process.state == state }
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title)
                Spacer()
                Text(services.count, format: .number).monospacedDigit()
            }.font(.system(size: 11)).foregroundStyle(DS.muted).padding(.bottom, 4)
            ForEach(services) { service in
                Button {
                    model.inspect(service)
                } label: {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 6) {
                            ServiceIcon(service: service, size: 18)
                            Text(service.title).font(.system(size: 12, weight: .medium)).lineLimit(1)
                        }
                        Text(service.process.projectName).font(.system(size: 11)).foregroundStyle(DS.muted).lineLimit(1)
                        address(service).font(.system(size: 10, design: .monospaced)).foregroundStyle(DS.muted)
                    }.padding(12).frame(maxWidth: .infinity, alignment: .leading).surface(radius: 12)
                }.buttonStyle(.plain)
            }
            if services.isEmpty {
                Text("Keine Prozesse").font(.system(size: 11)).foregroundStyle(DS.muted).padding(.vertical, 18)
            }
        }.frame(maxWidth: .infinity, alignment: .topLeading)
    }
    private func address(_ service: ServiceRecord) -> Text {
        if let endpoint = service.primaryEndpoint { return Text(verbatim: ":\(endpoint.port)") }
        return Text("PID \(String(service.id.pid))")
    }
}

struct InspectorView: View {
    @Bindable var model: MonitorModel
    let surface: MonitorSurface
    var body: some View {
        if let service = model.selected {
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
                    if let directory = service.process.workingDirectory {
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
                            }
                        }
                    }
                    if !service.endpoints.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("ADRESSEN").overline()
                            ForEach(service.endpoints, id: \.self) { endpoint in
                                HStack {
                                    Text(verbatim: "\(endpoint.address):\(endpoint.port)")
                                        .font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                                    Spacer()
                                    IconButton(symbol: "arrow.up.forward.square", help: "Adresse öffnen") {
                                        model.openEndpoint(endpoint)
                                    }
                                    .disabled(model.demoMode)
                                    IconButton(symbol: "doc.on.doc", help: "Adresse kopieren") {
                                        model.copy(
                                            endpoint.url?.absoluteString ?? "\(endpoint.address):\(endpoint.port)")
                                    }
                                    if let target = model.tunnelTarget(service, endpoint: endpoint) {
                                        ShareServerButton(model: model, target: target, surface: surface)
                                    }
                                }
                            }
                            if service.endpoints.contains(where: \.isNetworkExposed) {
                                Label("Auch im Netzwerk erreichbar", systemImage: "network")
                                    .font(.system(size: 10)).foregroundStyle(DS.orange)
                            }
                            if service.kind == .server {
                                Text(
                                    "Teilen erstellt einen öffentlichen Link. Jeder mit dem Link kann den Server aufrufen."
                                )
                                .font(.system(size: 10)).foregroundStyle(DS.muted).lineSpacing(3)
                            }
                            ForEach(model.visibleTunnels(for: service)) { record in
                                TunnelStatusRow(model: model, record: record)
                            }
                        }
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
                    if service.kind == .agent {
                        Text(
                            "Der Status beschreibt den Prozess. Chat-Inhalte und Aufgabenfortschritt werden nicht ausgelesen."
                        )
                        .font(.system(size: 10)).foregroundStyle(DS.muted).lineSpacing(3)
                    }
                    HStack(spacing: 8) {
                        Button {
                            model.activate(service)
                        } label: {
                            Label(
                                service.isDesktopApplication ? "App öffnen" : "Terminal",
                                systemImage: "arrow.up.forward.square")
                        }.buttonStyle(QuietButton()).disabled(
                            model.demoMode || (!service.isDesktopApplication && service.process.workingDirectory == nil)
                        )
                        Spacer()
                        Button {
                            model.request(
                                service.process.state == .paused ? .resume : .pause, service: service, from: surface)
                        } label: {
                            Label(
                                service.process.state == .paused ? "Fortsetzen" : "Pausieren",
                                systemImage: service.process.state == .paused ? "play" : "pause")
                        }.buttonStyle(QuietButton()).disabled(!model.canControl(service))
                        IconButton(symbol: "stop.circle", help: "Prozess stoppen…", tint: DS.red) {
                            model.request(.terminate, service: service, from: surface)
                        }.disabled(!model.canControl(service))
                    }
                }.padding(16)
            }
        } else {
            EmptyState(
                symbol: "checkmark.circle", title: "Prozess nicht mehr aktiv",
                detail: "Über den Zurück-Pfeil gelangst du zur Liste.")
        }
    }
}

struct StopConfirmation: View {
    @Bindable var model: MonitorModel
    let pending: PendingAction
    let dismiss: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("\(pending.service.title) stoppen?").font(.system(size: 17, weight: .medium))
            Text(
                "Laufende Arbeit im Projekt „\(pending.service.process.projectName)“ wird unterbrochen. Der Prozess (PID \(String(pending.service.id.pid))) wird zum Beenden aufgefordert."
            )
            .font(.system(size: 12)).foregroundStyle(DS.muted).lineSpacing(3)
            Text(
                "Extern gestartete Prozesse werden nicht automatisch neu gestartet. Kindprozesse werden nicht einzeln beendet."
            )
            .font(.system(size: 11)).foregroundStyle(DS.muted).lineSpacing(3)
            HStack {
                Spacer()
                Button("Abbrechen") { dismiss() }.buttonStyle(QuietButton()).keyboardShortcut(.cancelAction)
                Button("Stoppen", role: .destructive) {
                    model.perform(pending.action, service: pending.service)
                    dismiss()
                }.buttonStyle(QuietButton(tint: DS.red))
            }
        }.padding(24).frame(width: DS.panelWidth).background(PanelGlass())
    }
}

/// Shared visual identity for live rows and the read-only onboarding preview.
struct ServiceIdentityLabel: View {
    let service: ServiceRecord
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                if let endpoint = service.primaryEndpoint {
                    Text(verbatim: ":\(endpoint.port)").font(.system(size: 14, design: .monospaced))
                    Text(service.title).foregroundStyle(DS.tint(service)).lineLimit(1)
                    if service.process.state == .paused {
                        Image(systemName: "pause.circle").foregroundStyle(DS.orange).font(.system(size: 11))
                    }
                } else {
                    ServiceIcon(service: service, size: 18)
                    Text(service.title).lineLimit(1)
                    if service.process.state == .paused {
                        Image(systemName: "pause.circle").foregroundStyle(DS.orange).font(.system(size: 11))
                    }
                }
            }.font(.system(size: 13, weight: .medium))
            HStack(spacing: 6) {
                Image(systemName: "folder").font(.system(size: 11)).accessibilityHidden(true)
                location.font(.system(size: 11, design: .monospaced)).lineLimit(1).truncationMode(.middle)
            }.foregroundStyle(DS.muted)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private var location: Text {
        if let directory = service.process.workingDirectory { return Text(verbatim: Format.path(directory)) }
        return Text("PID \(String(service.id.pid))")
    }
}
