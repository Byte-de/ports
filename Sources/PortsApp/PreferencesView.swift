import PortsCore
import SwiftUI

struct PreferencesView: View {
    @Bindable var model: MonitorModel
    @State private var ruleName = ""
    @State private var executableName = ""
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                group("ERKENNUNG") {
                    Toggle(isOn: Binding(get: { model.isMonitoring }, set: { model.setMonitoring($0) })) {
                        settingLabel("Automatic detection")
                    }.toggleStyle(.switch).controlSize(.small).tint(DS.accent)
                        .accessibilityLabel("Automatic detection")
                    Divider().overlay(DS.line)
                    HStack {
                        settingLabel("Aktualisieren")
                        Spacer()
                        Picker("Intervall", selection: $model.preferences.refreshInterval) {
                            ForEach([2, 3, 5, 10], id: \.self) { seconds in
                                Text("\(seconds) seconds").tag(Double(seconds))
                            }
                        }.labelsHidden().frame(width: 130).onChange(of: model.preferences.refreshInterval) {
                            model.savePreferences()
                        }
                    }
                    Divider().overlay(DS.line)
                    Toggle(isOn: $model.preferences.showOtherListeners) {
                        settingLabel(
                            "Alle TCP-Listener anzeigen",
                            detail: "Auch Dienste ohne erkanntes Entwicklungs-Framework anzeigen.")
                    }.toggleStyle(.switch).controlSize(.small).tint(DS.accent)
                        .accessibilityLabel("Alle TCP-Listener anzeigen").onChange(
                            of: model.preferences.showOtherListeners
                        ) { model.savePreferences() }
                }
                group("SCHNELLER ZUGRIFF") {
                    Toggle(isOn: $model.preferences.showNotch) {
                        settingLabel(
                            "Notch panel",
                            detail: "Opens \(AppInfo.name) at the top of the screen instead of in a window.")
                    }.toggleStyle(.switch).controlSize(.small).tint(DS.accent)
                        .accessibilityLabel("Notch panel").onChange(of: model.preferences.showNotch) {
                            model.savePreferences()
                            PanelWindowCoordinator.shared.configureNotch(model: model)
                        }
                }
                DisclosureGroup {
                    agentRules.padding(.top, 10)
                } label: {
                    HStack {
                        Text("Eigene Agenten")
                        Spacer()
                        if !model.preferences.agentRules.isEmpty {
                            Text(model.preferences.agentRules.count, format: .number).monospacedDigit()
                                .foregroundStyle(DS.muted)
                        }
                    }.frame(minHeight: 40).contentShape(Rectangle())
                }.font(.system(size: 12, weight: .medium)).tint(DS.muted)
                Divider().overlay(DS.line)
                HStack(spacing: 8) {
                    Button("Einführung ansehen") { model.presentOnboarding() }.buttonStyle(QuietButton())
                    Button(model.demoMode ? "Live anzeigen" : "Demo öffnen") { model.toggleDemo() }
                        .buttonStyle(QuietButton())
                }
                DisclosureGroup {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Lokale Erkennung. Ohne Telemetrie.").font(.system(size: 12, weight: .medium))
                        Text(
                            "Byte Ports liest Prozesse des angemeldeten Benutzers und deren TCP-Listener. Chat-Inhalte und Aufgabenfortschritt werden nicht ausgelesen. Agenten in entfernten Umgebungen oder innerhalb von Containern benötigen eigene Integrationen. Ports sind Listener-Nachweise, keine HTTP-Healthchecks. Externe Prozesse bieten keine nachträglich abrufbaren stdout-Logs."
                        )
                        .font(.system(size: 11)).foregroundStyle(DS.muted).lineSpacing(4)
                        Text(
                            "Öffentlich teilen verbindet den gewählten HTTP-Server mit Cloudflare. Jeder mit dem Link kann ihn aufrufen. Freigaben enden beim Stoppen oder Beenden von Byte Ports. Die manuelle Update-Prüfung fragt GitHub nach der neuesten Version."
                        ).font(.system(size: 11)).foregroundStyle(DS.muted).lineSpacing(4)
                    }.padding(.top, 10)
                } label: {
                    Text("Über Byte Ports").frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)
                        .contentShape(Rectangle())
                }.font(.system(size: 12, weight: .medium)).tint(DS.muted)
                updateControls
                HStack {
                    Text(verbatim: "\(AppInfo.name) \(AppInfo.version)")
                        .font(.system(size: 10)).foregroundStyle(DS.muted)
                    Spacer()
                    Button("Beenden") { QuitCoordinator.shared.requestQuit() }.buttonStyle(QuietButton())
                }
            }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
        }.scrollIndicators(.hidden)
    }

    @ViewBuilder private var updateControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button("Nach Updates suchen") { model.checkForUpdates() }.buttonStyle(QuietButton())
                .disabled(
                    {
                        if case .checking = model.updateStatus { return true }
                        return false
                    }())
            switch model.updateStatus {
            case .idle: EmptyView()
            case .checking: Text("Update wird geprüft…").foregroundStyle(DS.muted)
            case .current: Text("Byte Ports ist aktuell.").foregroundStyle(DS.muted)
            case .available(let release):
                Link("Version \(release.version.string) laden ↗", destination: release.url).foregroundStyle(DS.accent)
            case .failed(let message): Text(message).foregroundStyle(DS.muted)
            }
        }.font(.system(size: 11))
    }

    private var agentRules: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Exakter Dateiname oder Einstiegsskript, ohne Dateiendung.")
                .font(.system(size: 11)).foregroundStyle(DS.muted)
            ForEach(model.preferences.agentRules) { rule in
                HStack {
                    Text(rule.name).font(.system(size: 12))
                    Text(rule.executableName).font(.system(size: 10, design: .monospaced)).foregroundStyle(DS.muted)
                    Spacer()
                    IconButton(symbol: "minus.circle", help: "Regel entfernen") {
                        model.preferences.agentRules.removeAll { $0.id == rule.id }
                        model.savePreferences()
                        Task { await model.refresh() }
                    }
                }
            }
            HStack(spacing: 10) {
                TextField("Anzeigename", text: $ruleName).textFieldStyle(.roundedBorder)
                TextField("z. B. my-agent", text: $executableName).textFieldStyle(.roundedBorder)
                Button("Hinzufügen") {
                    model.preferences.agentRules.append(
                        AgentRule(
                            name: ruleName.trimmingCharacters(in: .whitespaces),
                            executableName: executableName.trimmingCharacters(in: .whitespaces).lowercased()))
                    ruleName = ""
                    executableName = ""
                    model.savePreferences()
                    Task { await model.refresh() }
                }.buttonStyle(QuietButton(tint: DS.accent))
                    .disabled(
                        ruleName.trimmingCharacters(in: .whitespaces).isEmpty
                            || executableName.trimmingCharacters(in: .whitespaces).isEmpty
                            || executableName.contains("/"))
            }.font(.system(size: 11))
        }
    }

    private func group<Content: View>(_ title: LocalizedStringResource, @ViewBuilder content: () -> Content)
        -> some View
    {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).overline()
            content()
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private func settingLabel(_ title: LocalizedStringResource, detail: LocalizedStringResource? = nil) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 12, weight: .medium))
            if let detail {
                Text(detail).font(.system(size: 11)).foregroundStyle(DS.muted)
                    .fixedSize(horizontal: false, vertical: true).lineSpacing(3)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}
