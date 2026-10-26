import PortsCore
import SwiftUI

struct ShareServerButton: View {
    @Bindable var model: MonitorModel
    let target: TunnelTarget
    let surface: MonitorSurface
    private var record: TunnelRecord? { model.tunnelRecord(target) }
    private var help: String {
        return record?.phase == .ready ? "Freigabelink kopieren" : "Öffentlich teilen"
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

struct PublicShareConfirmation: View {
    @Bindable var model: MonitorModel
    let target: TunnelTarget

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label("Server öffentlich teilen?", systemImage: "globe")
                .font(.system(size: 17, weight: .medium))
            Text(
                "Jeder mit dem Link kann auf diesen Server zugreifen. Die Verbindung läuft über Cloudflare, ohne zusätzlichen Passwortschutz."
            )
            .font(.system(size: 12)).foregroundStyle(DS.muted).lineSpacing(4)
            Text(
                "Teile nur Inhalte, die öffentlich sein dürfen. Die Freigabe endet, sobald du sie stoppst oder Byte Ports beendest."
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

    private var title: String {
        switch record.phase {
        case .starting: "Cloudflare verbindet…"
        case .ready: "Öffentlich · Cloudflare"
        case .reconnecting: "Verbindung wird erneuert…"
        case .stopping: "Freigabe wird beendet…"
        case .stopped: "Freigabe beendet"
        case .failed: "Freigabe beendet"
        }
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
                Text(title).font(.system(size: 10, weight: .medium)).foregroundStyle(DS.muted)
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
                    Text(record.message ?? "Port \(String(record.target.endpoint.port)) · Abbrechen jederzeit möglich")
                        .font(.system(size: 10)).foregroundStyle(DS.muted).lineLimit(1)
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
