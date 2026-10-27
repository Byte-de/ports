import PortsCore
import SwiftUI

struct ShareServerButton: View {
    @Bindable var model: MonitorModel
    let target: TunnelTarget
    let surface: MonitorSurface
    private var record: TunnelRecord? { model.tunnelRecord(target) }
    private var help: LocalizedStringResource {
        // Busy covers the HTTP check and the client launch, before a share record exists.
        if model.sharingBusy.contains(target.id) { return "Preparing share…" }
        return record?.phase == .ready ? "Copy share link" : "Share publicly"
    }
    private var working: Bool {
        model.sharingBusy.contains(target.id) || [.starting, .reconnecting, .stopping].contains(record?.phase)
    }
    var body: some View {
        IconButton(
            symbol: "link", help: help,
            tint: record?.phase == .ready ? DS.accent : DS.muted
        ) {
            model.share(target, from: surface)
        }
        .disabled(model.demoMode || working || model.isQuitting || model.isSwitchingDemo)
        .accessibilityHint(
            "Erstellt einen öffentlichen Cloudflare-Link. Jeder mit dem Link kann diesen Server aufrufen.")
    }
}

/// 127.0.0.1, ::1 and * on one port are one server: one row, and open, copy and share all use its primary address.
struct ServiceAddressSection: View {
    @Bindable var model: MonitorModel
    let service: ServiceRecord
    let surface: MonitorSurface

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("ADDRESSES").overline()
            ForEach(service.ports) { port in
                HStack(spacing: 8) {
                    Text(verbatim: ":\(port.port)").font(.system(size: 12, design: .monospaced))
                        .textSelection(.enabled)
                    Text(verbatim: Format.addressSummary(port.endpoints)).font(.system(size: 11))
                        .foregroundStyle(DS.muted).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                    Spacer()
                    IconButton(symbol: "arrow.up.forward.square", help: "Open in browser") {
                        model.openEndpoint(port.primary)
                    }
                    .disabled(model.demoMode)
                    IconButton(symbol: "doc.on.doc", help: "Copy URL") {
                        model.copy(port.primary.url?.absoluteString ?? "\(port.primary.address):\(port.port)")
                    }
                    if let target = model.tunnelTarget(service, endpoint: port.primary) {
                        ShareServerButton(model: model, target: target, surface: surface)
                    } else if model.answersNoHTTP(service, port: port.port) {
                        Text("No HTTP").font(.system(size: 10)).foregroundStyle(DS.muted)
                            .help("Doesn't answer HTTP – can't be shared")
                    }
                }
                if let record = model.tunnelRecord(for: service.id, port: port.port), record.phase != .stopped {
                    TunnelStatusRow(model: model, record: record)
                }
            }
            // A share whose port closed keeps its notice, which says why it ended, until it is dismissed.
            ForEach(model.visibleTunnels(for: service).filter { !portNumbers.contains($0.id.port) }) { record in
                TunnelStatusRow(model: model, record: record)
            }
            if service.ports.contains(where: \.isNetworkExposed) {
                Label("Also reachable on your network", systemImage: "network")
                    .font(.system(size: 10)).foregroundStyle(DS.orange)
            }
        }
    }

    private var portNumbers: Set<UInt16> { Set(service.ports.map(\.port)) }
}

struct PublicShareConfirmation: View {
    @Bindable var model: MonitorModel
    let target: TunnelTarget

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label("Server öffentlich teilen?", systemImage: "globe")
                .font(.system(size: 17, weight: .medium))
            Text(
                "Anyone with the link can reach this server through Cloudflare, without a password. Sharing ends when you stop it or quit the app."
            )
            .font(.system(size: 12)).foregroundStyle(DS.muted).lineSpacing(4)
            HStack {
                Text("Port \(String(target.endpoint.port))").font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(DS.accent)
                Spacer()
                Button("Abbrechen") { model.dismissPanelDialog() }
                    .buttonStyle(QuietButton()).keyboardShortcut(.cancelAction)
                Button("Öffentlich teilen") { model.confirmPublicSharing() }
                    .buttonStyle(AccentButton())
            }
        }.padding(24).frame(width: DS.panelWidth).background(PanelGlass())
    }
}

struct TunnelStatusRow: View {
    @Bindable var model: MonitorModel
    let record: TunnelRecord
    private var accessibility = PanelAccessibility()

    init(model: MonitorModel, record: TunnelRecord) {
        self.model = model
        self.record = record
    }

    private var detail: Text {
        if let message = record.message { return Text(verbatim: message) }
        return Text("Port \(String(record.target.endpoint.port)) · Abbrechen jederzeit möglich")
    }
    var body: some View {
        HStack(spacing: 8) {
            ZStack {
                if [.starting, .reconnecting, .stopping].contains(record.phase) {
                    if accessibility.reduceMotion {
                        Image(systemName: "ellipsis").foregroundStyle(DS.muted)
                    } else {
                        ProgressView().controlSize(.mini)
                    }
                } else {
                    Image(systemName: record.phase == .ready ? "globe" : "exclamationmark.circle")
                        .font(.system(size: 12)).foregroundStyle(record.phase == .ready ? DS.accent : DS.orange)
                }
            }.frame(width: 16).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(record.phase.statusTitle).font(.system(size: 10, weight: .medium)).foregroundStyle(DS.muted)
                    .contentTransition(.opacity)
                if let url = record.publicURL, record.phase == .ready {
                    Button {
                        model.copy(url.absoluteString, message: "Freigabelink kopiert")
                    } label: {
                        Text(url.host ?? url.absoluteString).font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(DS.accent).lineLimit(1).truncationMode(.middle)
                    }.buttonStyle(.plain).help("Freigabelink kopieren")
                        .accessibilityLabel("Freigabelink kopieren: \(url.absoluteString)")
                        .transition(.opacity)
                } else {
                    detail.font(.system(size: 10)).foregroundStyle(DS.muted).lineLimit(1)
                        .help(record.message ?? "")
                        .transition(.opacity)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
            IconButton(symbol: "xmark", help: record.phase.isActive ? "Freigabe beenden" : "Hinweis schließen") {
                model.stopSharing(record)
            }.disabled(record.phase == .stopping)
        }.frame(height: 48)
            .animation(PanelMotion.fade(accessibility.reduceMotion ? 0.10 : 0.14), value: record.phase)
            .accessibilityElement(children: .contain)
    }
}
