import AppKit
import PortsCore
import PortsFeatures
import SwiftUI

struct ActionsView: View {
    @Bindable var model: MonitorModel
    let surface: MonitorSurface
    var body: some View {
        let rows = LaunchListing.rows(saved: model.preferences.launchConfigurations, jobs: model.launches)
        Group {
            if model.showingLogs {
                logs
            } else if rows.saved.isEmpty && rows.oneOff.isEmpty {
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
                        if !rows.saved.isEmpty {
                            header("SAVED", clearsFinished: true)
                            ForEach(rows.saved) { row in
                                LaunchRowView(model: model, row: row, surface: surface)
                                Rectangle().fill(DS.line).frame(height: 0.5)
                            }
                        }
                        if !rows.oneOff.isEmpty {
                            header("RUN ONCE", clearsFinished: rows.saved.isEmpty)
                            ForEach(rows.oneOff) { row in
                                LaunchRowView(model: model, row: row, surface: surface)
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
                await model.reloadLaunches()
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
            }
        }
    }

    /// Clear Finished sits in the first header, whichever section that is.
    private func header(_ title: LocalizedStringResource, clearsFinished: Bool) -> some View {
        HStack {
            Text(title).overline()
            Spacer()
            if clearsFinished && model.launches.contains(where: { !$0.state.isActive }) {
                Button("Clear Finished") { model.removeFinishedJobs() }.buttonStyle(.plain)
                    .font(.system(size: 11)).foregroundStyle(DS.muted).disabled(model.demoMode)
            }
        }.padding(.top, 16).padding(.bottom, 4)
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

/// A saved action or a launched slot. The leading glyph and the subtitle show its phase; at most two controls trail.
private struct LaunchRowView: View {
    private enum Phase: Equatable {
        case idle, loading
        case running(since: Date)
        case stopping, restarting, unresponsive, stopped, finished
        case failed(exit: Int32)
    }
    private static let stopLabel = LocalizedStringResource(
        "job.stopEllipsis", defaultValue: "Stop…", comment: "Asks to confirm stopping a launched action")

    @Bindable var model: MonitorModel
    let row: LaunchRow
    let surface: MonitorSurface
    @State private var hovered = false
    @FocusState private var removeFocused: Bool

    private var phase: Phase {
        if model.loadingShellEnvironment.contains(row.id) { return .loading }
        guard let job = row.job else { return .idle }
        if model.restartingJobs.contains(job.id) { return .restarting }
        // A stop or force stop in progress shows at once, before the next read of the slot.
        let busy = model.busyJobs.contains(job.id)
        switch job.state {
        case .running: return busy ? .stopping : .running(since: job.startedAt)
        case .stopping: return .stopping
        case .unresponsive: return busy ? .stopping : .unresponsive
        case .stopped: return .stopped
        case .finished: return .finished
        case .failed: return .failed(exit: job.exitCode ?? -1)
        }
    }

    private var isRunning: Bool {
        if case .running = phase { return true }
        return false
    }

    var body: some View {
        HStack(spacing: 8) {
            glyph.font(.system(size: 12)).frame(width: 16).accessibilityHidden(true)
            if let job = row.job {
                Button {
                    model.showLogs(job)
                } label: {
                    labels
                }.buttonStyle(.plain).help("Show Output")
            } else {
                labels
            }
            controls
        }
        .onHover { hovered = $0 }
        .contextMenu { menu }
    }

    private var labels: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(verbatim: row.configuration.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
            subtitle.font(.system(size: 11, design: phase == .idle ? .monospaced : .default))
                .foregroundStyle(subtitleTint).lineLimit(1)
        }.frame(maxWidth: .infinity, alignment: .leading).frame(height: DS.rowHeight).contentShape(Rectangle())
    }

    @ViewBuilder private var glyph: some View {
        switch phase {
        case .idle: Image(systemName: "bolt").foregroundStyle(DS.muted)
        case .running: Circle().fill(DS.accent).frame(width: 6, height: 6)
        case .loading, .stopping, .restarting: ProgressView().controlSize(.mini)
        case .unresponsive: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(DS.orange)
        case .stopped, .finished: Image(systemName: "checkmark").foregroundStyle(DS.muted)
        case .failed: Image(systemName: "xmark").foregroundStyle(DS.red)
        }
    }

    private var subtitle: Text {
        switch phase {
        case .idle: Text(verbatim: row.configuration.command)
        case .loading: Text("Loading shell environment…")
        case .running(let since): Text("Running · \(since.formatted(date: .omitted, time: .shortened))")
        case .stopping: Text("Stopping…")
        case .restarting: Text("Restarting…")
        case .unresponsive: Text("Not responding")
        case .stopped: Text("Stopped")
        case .finished: Text("Exited")
        case .failed(let exit): Text("Failed · exit \(exit)")
        }
    }

    private var subtitleTint: Color {
        switch phase {
        case .running: DS.accent
        case .unresponsive: DS.orange
        case .failed: DS.red
        default: DS.muted
        }
    }

    @ViewBuilder private var controls: some View {
        switch phase {
        case .idle, .stopped, .finished, .failed:
            if !row.isSaved {
                // Revealed by hover or keyboard focus, so finished one-off rows stay quiet.
                let revealed = hovered || removeFocused
                IconButton(symbol: "xmark", help: "Remove from List") { remove() }
                    .focused($removeFocused).opacity(revealed ? 1 : 0).allowsHitTesting(revealed)
                    .disabled(model.demoMode)
            }
            IconButton(
                symbol: "play", help: row.job == nil ? "Start “\(row.configuration.name)”" : "Start Again"
            ) { start() }
            .disabled(model.demoMode || model.isLaunching)
        case .running:
            IconButton(symbol: "arrow.clockwise", help: "Restart") { restart() }.disabled(model.demoMode)
            IconButton(symbol: "stop.circle", help: Self.stopLabel, tint: DS.red) { requestStop() }
                .disabled(model.demoMode)
        case .unresponsive:
            IconButton(symbol: "xmark.octagon", help: "Force Stop…", tint: DS.red) {
                if let job = row.job { model.requestForceStop(job, from: surface) }
            }.disabled(model.demoMode)
        case .loading, .stopping, .restarting:
            EmptyView()
        }
    }

    @ViewBuilder private var menu: some View {
        Button("Start") { start() }
            .disabled(row.job?.state.isActive == true || model.demoMode || model.isLaunching)
        if let job = row.job {
            Button("Show Output") { model.showLogs(job) }
            Button("Restart") { restart() }.disabled(!isRunning || model.demoMode)
            Button(role: .destructive) {
                requestStop()
            } label: {
                Text(Self.stopLabel)
            }.disabled(!isRunning || model.demoMode)
        }
        Divider()
        Button("Copy Command") { model.copy(row.configuration.command) }
        if row.isSaved {
            // The demo lists the real saved actions, so deleting one there would change the user's settings.
            Button("Aktion entfernen", role: .destructive) {
                model.preferences.launchConfigurations.removeAll { $0.id == row.id }
                model.savePreferences()
            }.disabled(model.demoMode || model.isQuitting)
        } else {
            Button("Remove from List", role: .destructive) { remove() }
                .disabled(row.job?.state.isActive != false || model.demoMode)
        }
    }

    private func start() {
        model.presentationSurface = surface
        model.run(row.configuration, save: false)
    }

    private func restart() {
        guard let job = row.job else { return }
        model.presentationSurface = surface
        model.restartJob(job)
    }

    private func requestStop() {
        if let job = row.job { model.requestJobStop(job, from: surface) }
    }

    private func remove() {
        if let job = row.job { model.removeJob(job) }
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
    @State private var startedID: UUID?
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
            Text("Runs in zsh with your shell's environment variables. Aliases aren't available.")
                .font(.system(size: 11)).foregroundStyle(DS.muted).lineSpacing(4)
            if let validation {
                Label(validation, systemImage: "exclamationmark.circle").font(.system(size: 11)).foregroundStyle(
                    DS.orange)
            }
            HStack {
                if let startedID, model.loadingShellEnvironment.contains(startedID) {
                    Text("Loading shell environment…").font(.system(size: 11)).foregroundStyle(DS.muted)
                }
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
            startedID = configuration.id
            model.run(configuration, save: save, fromForm: true)
        } catch { validation = error.localizedDescription }
    }
}

struct JobStopConfirmation: View {
    @Bindable var model: MonitorModel
    let job: LaunchRecord
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Stop “\(job.configuration.name)”?").font(.system(size: 17, weight: .medium))
            Text("The service and its subprocesses will be asked to quit.")
                .font(.system(size: 12)).foregroundStyle(DS.muted).lineSpacing(3)
            HStack {
                Spacer()
                Button("Cancel") { model.dismissPanelDialog() }.buttonStyle(QuietButton())
                    .keyboardShortcut(.cancelAction)
                Button(role: .destructive) {
                    model.dismissPanelDialog()
                    model.stopJob(job)
                } label: {
                    Text(
                        LocalizedStringResource(
                            "job.stop", defaultValue: "Stop", comment: "Confirms stopping a launched action"))
                }.buttonStyle(QuietButton(tint: DS.red))
            }
        }.padding(24).frame(width: DS.panelWidth).background(PanelGlass())
    }
}

/// Offered only after a stop timed out. Return never confirms it: losing unsaved data takes a deliberate click.
struct ForceStopConfirmation: View {
    @Bindable var model: MonitorModel
    let pending: PendingForceStop
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Force stop “\(pending.job.configuration.name)”?").font(.system(size: 17, weight: .medium))
            consequence.font(.system(size: 12)).foregroundStyle(DS.muted).lineSpacing(3)
            HStack {
                Spacer()
                Button("Cancel") { model.dismissPanelDialog() }.buttonStyle(QuietButton())
                    .keyboardShortcut(.cancelAction)
                Button("Force Stop", role: .destructive) {
                    model.dismissPanelDialog()
                    model.forceStop(pending)
                }.buttonStyle(QuietButton(tint: DS.red))
            }
        }.padding(24).frame(width: DS.panelWidth).background(PanelGlass())
    }
    private var consequence: Text {
        let name = pending.job.configuration.name
        guard pending.restartAfter else {
            return Text(
                "“\(name)” isn't responding to Stop. Force Stop ends the service and its subprocesses without cleanup; unsaved data may be lost."
            )
        }
        return Text(
            "“\(name)” isn't responding to Stop. Force Stop ends the service and its subprocesses without cleanup; unsaved data may be lost. It restarts afterwards."
        )
    }
}
