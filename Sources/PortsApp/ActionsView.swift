import AppKit
import PortsCore
import SwiftUI

struct ActionsView: View {
    @Bindable var model: MonitorModel
    let surface: MonitorSurface
    private var savedActions: [LaunchConfiguration] {
        model.preferences.launchConfigurations.filter {
            model.search.isEmpty || $0.name.localizedCaseInsensitiveContains(model.search)
                || $0.command.localizedCaseInsensitiveContains(model.search)
        }
    }
    var body: some View {
        Group {
            if model.showingLogs {
                logs
            } else if savedActions.isEmpty && model.launches.isEmpty {
                VStack(spacing: 14) {
                    EmptyState(
                        symbol: "bolt", title: "Ein Befehl. Ein Klick.",
                        detail: "Speichere einen Startbefehl mit seinem Projektordner.")
                    Button {
                        model.presentLaunch(from: surface)
                    } label: {
                        Label("Aktion hinzufügen", systemImage: "plus")
                    }.buttonStyle(QuietButton()).disabled(model.demoMode).padding(.bottom, 28)
                }
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        if !savedActions.isEmpty {
                            Text("GESPEICHERT").overline().padding(.top, 16).padding(.bottom, 4)
                            ForEach(savedActions) { configuration in
                                HStack(spacing: 8) {
                                    Image(systemName: "bolt").foregroundStyle(DS.muted)
                                    VStack(alignment: .leading, spacing: 5) {
                                        Text(configuration.name).font(.system(size: 12, weight: .medium))
                                        Text(configuration.command).font(.system(size: 11, design: .monospaced))
                                            .foregroundStyle(DS.muted).lineLimit(1)
                                    }
                                    Spacer()
                                    IconButton(symbol: "play", help: "\(configuration.name) starten") {
                                        model.presentationSurface = surface
                                        model.run(configuration, save: false)
                                    }.disabled(
                                        model.demoMode || model.isLaunching
                                            || model.launches.contains {
                                                $0.configuration.id == configuration.id && $0.state == .running
                                            })
                                }.frame(height: 64)
                                    .contextMenu {
                                        Button("Befehl kopieren") { model.copy(configuration.command) }
                                        Button("Aktion entfernen", role: .destructive) {
                                            model.preferences.launchConfigurations.removeAll {
                                                $0.id == configuration.id
                                            }
                                            model.savePreferences()
                                        }
                                    }
                                Rectangle().fill(DS.line).frame(height: 0.5)
                            }
                        }
                        if !model.launches.isEmpty {
                            Text("GESTARTET").overline().padding(.top, 16).padding(.bottom, 4)
                            ForEach(model.launches) { job in
                                HStack(spacing: 4) {
                                    Button {
                                        model.showLogs(job)
                                    } label: {
                                        VStack(alignment: .leading, spacing: 5) {
                                            Text(job.configuration.name).font(.system(size: 12, weight: .medium))
                                                .lineLimit(1)
                                            Text(
                                                job.state == .running
                                                    ? "Läuft"
                                                    : (job.state == .failed ? "Exit \(job.exitCode ?? -1)" : "Beendet")
                                            )
                                            .font(.system(size: 11)).foregroundStyle(
                                                job.state == .running ? DS.accent : DS.muted)
                                        }.frame(maxWidth: .infinity, alignment: .leading).frame(height: 64)
                                            .contentShape(Rectangle())
                                    }.buttonStyle(.plain)
                                    IconButton(symbol: "text.alignleft", help: "Ausgabe anzeigen") {
                                        model.showLogs(job)
                                    }
                                    IconButton(symbol: "arrow.clockwise", help: "Dienst neu starten") {
                                        model.presentationSurface = surface
                                        model.manageJob(job, restart: true)
                                    }.disabled(model.demoMode || model.busyJobs.contains(job.id))
                                    IconButton(symbol: "stop.circle", help: "Dienst stoppen…", tint: DS.red) {
                                        model.requestJobStop(job, from: surface)
                                    }
                                    .disabled(
                                        model.demoMode || job.state != .running || model.busyJobs.contains(job.id))
                                }
                                Rectangle().fill(DS.line).frame(height: 0.5)
                            }
                        }
                    }.padding(.horizontal, 16)
                }
            }
        }
        .task(id: model.showingLogs ? model.logJobID : nil) {
            guard model.showingLogs, let id = model.logJobID else { return }
            while !Task.isCancelled {
                model.logs = await model.launcher.output(for: id)
                model.launches = await model.launcher.records()
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
            }
        }
    }

    private var logs: some View {
        VStack(spacing: 0) {
            HStack {
                logTitle.font(.system(size: 12)).foregroundStyle(DS.muted).lineLimit(1)
                Spacer()
                IconButton(symbol: "doc.on.doc", help: "Ausgabe kopieren") { model.copy(model.logs) }
            }.padding(.horizontal, 16)
            ScrollView([.vertical, .horizontal]) {
                (model.logs.isEmpty ? Text("Noch keine Ausgabe…") : Text(verbatim: model.logs))
                    .font(.system(size: 11, design: .monospaced)).foregroundStyle(DS.text)
                    .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .topLeading).padding(16)
            }
            Text("Letzte 256 KB · stdout + stderr").font(.system(size: 9)).foregroundStyle(DS.muted).padding(.top, 8)
        }
    }

    private var logTitle: Text {
        if let job = model.launches.first(where: { $0.id == model.logJobID }) {
            return Text(verbatim: job.configuration.name)
        }
        return Text("Dienst")
    }
}

struct LaunchForm: View {
    private enum Field: Hashable { case name, command, directory }
    @Bindable var model: MonitorModel
    let dismiss: () -> Void
    @State private var name = ""
    @State private var command = ""
    @State private var directory = ""
    @State private var save = true
    @State private var validation: String?
    @FocusState private var focusedField: Field?

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack {
                Text("Dienst starten").font(.system(size: 17, weight: .medium))
                Spacer()
                IconButton(symbol: "xmark", help: "Schließen", action: dismiss)
            }
            field("NAME", placeholder: String(localized: "Zum Beispiel: Frontend"), value: $name, focus: .name)
            field("BEFEHL", placeholder: "npm run dev", value: $command, focus: .command, monospaced: true)
            VStack(alignment: .leading, spacing: 9) {
                Text("PROJEKTORDNER").overline()
                HStack(spacing: 8) {
                    TextField("/Pfad/zum/Projekt", text: $directory).font(.system(size: 12, design: .monospaced))
                        .textFieldStyle(.plain)
                        .focused($focusedField, equals: .directory)
                        .padding(11).background(DS.background, in: RoundedRectangle(cornerRadius: 8))
                    Button("Auswählen…") {
                        let panel = NSOpenPanel()
                        panel.canChooseDirectories = true
                        panel.canChooseFiles = false
                        panel.allowsMultipleSelection = false
                        if panel.runModal() == .OK, let url = panel.url { directory = url.path }
                    }.buttonStyle(QuietButton())
                }
            }
            Toggle("Als Startaktion speichern", isOn: $save).toggleStyle(.checkbox).font(.system(size: 12))
            Text(
                "Der Befehl läuft in einer zsh-Login-Shell im gewählten Ordner. Interaktive Agenten startest du weiterhin im Terminal; Byte Ports erkennt sie automatisch."
            )
            .font(.system(size: 11)).foregroundStyle(DS.muted).lineSpacing(4)
            if let validation {
                Label(validation, systemImage: "exclamationmark.circle").font(.system(size: 11)).foregroundStyle(
                    DS.orange)
            }
            HStack {
                Spacer()
                Button("Abbrechen", action: dismiss).buttonStyle(QuietButton()).keyboardShortcut(.cancelAction)
                Button {
                    start()
                } label: {
                    Label("Dienst starten", systemImage: "play.fill")
                }.buttonStyle(AccentButton()).keyboardShortcut(.defaultAction)
                    .disabled(
                        name.isEmpty || command.isEmpty || directory.isEmpty || model.demoMode || model.isLaunching)
            }
        }.padding(24).frame(width: DS.panelWidth).background(PanelGlass())
            .task { focusedField = .name }
    }

    private func field(
        _ title: LocalizedStringResource, placeholder: String, value: Binding<String>, focus: Field,
        monospaced: Bool = false
    )
        -> some View
    {
        VStack(alignment: .leading, spacing: 9) {
            Text(title).overline()
            TextField(placeholder, text: value).font(.system(size: 12, design: monospaced ? .monospaced : .default))
                .textFieldStyle(.plain)
                .focused($focusedField, equals: focus)
                .padding(11).background(DS.background, in: RoundedRectangle(cornerRadius: 8))
                .accessibilityLabel(Text(title))
        }
    }

    private func start() {
        let configuration = LaunchConfiguration(
            name: name.trimmingCharacters(in: .whitespaces), command: command,
            directory: NSString(string: directory).expandingTildeInPath)
        do {
            try configuration.validate()
            model.run(configuration, save: save)
        } catch { validation = error.localizedDescription }
    }
}

struct JobStopConfirmation: View {
    @Bindable var model: MonitorModel
    let job: LaunchRecord
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("\(job.configuration.name) stoppen?").font(.system(size: 17, weight: .medium))
            Text("Der Dienst und seine von Byte Ports erfassten Kindprozesse werden zum Beenden aufgefordert.")
                .font(.system(size: 12)).foregroundStyle(DS.muted).lineSpacing(3)
            HStack {
                Spacer()
                Button("Abbrechen") { model.dismissPanelDialog() }.buttonStyle(QuietButton())
                    .keyboardShortcut(.cancelAction)
                Button("Stoppen", role: .destructive) {
                    model.dismissPanelDialog()
                    model.manageJob(job, restart: false)
                }.buttonStyle(QuietButton(tint: DS.red))
            }
        }.padding(24).frame(width: DS.panelWidth).background(PanelGlass())
    }
}
