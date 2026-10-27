import AppKit
import PortsCore
import PortsFeatures
import SwiftUI

struct ActionsView: View {
    @Bindable var model: MonitorModel
    let surface: MonitorSurface
    var body: some View {
        let rows = LaunchListing.rows(saved: model.preferences.launchConfigurations, jobs: model.launches)
        if rows.saved.isEmpty && rows.oneOff.isEmpty {
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
}

/// A slot's phase, as its row and its output page show it.
private enum LaunchPhase: Equatable {
    case idle, loading
    case running(since: Date)
    case stopping, restarting, unresponsive, stopped, finished
    case failed(exit: Int32)

    /// `id` is the configuration's, which its slot shares.
    @MainActor init(model: MonitorModel, id: UUID, job: LaunchRecord?) {
        if model.loadingShellEnvironment.contains(id) {
            self = .loading
            return
        }
        guard let job else {
            self = .idle
            return
        }
        if model.restartingJobs.contains(job.id) {
            self = .restarting
            return
        }
        // A stop or force stop in progress shows at once, before the next read of the slot.
        let busy = model.busyJobs.contains(job.id)
        self =
            switch job.state {
            case .running: busy ? .stopping : .running(since: job.startedAt)
            case .stopping: .stopping
            case .unresponsive: busy ? .stopping : .unresponsive
            case .stopped: .stopped
            case .finished: .finished
            case .failed: .failed(exit: job.exitCode ?? -1)
            }
    }

    var isRunning: Bool {
        if case .running = self { return true }
        return false
    }

    var hasEnded: Bool {
        switch self {
        case .stopped, .finished, .failed: true
        default: false
        }
    }

    /// An action that never ran shows its command.
    func subtitle(command: String) -> Text {
        switch self {
        case .idle: Text(verbatim: command)
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

    var tint: Color {
        switch self {
        case .running: DS.accent
        case .unresponsive: DS.orange
        case .failed: DS.red
        default: DS.muted
        }
    }
}

private let jobStopLabel = LocalizedStringResource(
    "job.stopEllipsis", defaultValue: "Stop…", comment: "Asks to confirm stopping a launched action")

/// A launched job's output, pushed over the Actions tab. New output streams in twice a second while this surface shows
/// the page, and the text follows the end until the user scrolls up.
struct LogPane: View {
    @Bindable var model: MonitorModel
    let jobID: UUID
    let surface: MonitorSurface
    @State private var feed = LogFeed()
    @State private var following = true
    @State private var isEmpty = false
    @State private var hasUnseenOutput = false

    private var job: LaunchRecord? { model.launches.first { $0.id == jobID } }
    /// The feed reads only while this surface is on screen.
    private var polledJob: UUID? { model.isShowing(surface) ? jobID : nil }

    var body: some View {
        VStack(spacing: 0) {
            if let job { subheader(job) }
            LogTextView(
                feed: feed, name: job?.configuration.name ?? "",
                onFollowChange: { isFollowing in
                    following = isFollowing
                    if isFollowing { hasUnseenOutput = false }
                },
                onEmptyChange: { isEmpty = $0 }, onUnseenOutput: { hasUnseenOutput = true }
            )
            .overlay {
                if isEmpty {
                    Text("No output yet…").font(.system(size: 11)).foregroundStyle(DS.muted).allowsHitTesting(false)
                }
            }
            .overlay(alignment: .bottom) {
                if hasUnseenOutput && !following { newOutputButton }
            }
            Text("Last 256 KB · stdout + stderr").font(.system(size: 9)).foregroundStyle(DS.muted).padding(.top, 8)
        }
        .task(id: polledJob) {
            if let polledJob { await feed.run(job: polledJob, launcher: model.launcher) }
        }
    }

    private func subheader(_ job: LaunchRecord) -> some View {
        let phase = LaunchPhase(model: model, id: job.id, job: job)
        return HStack(spacing: 8) {
            Circle().fill(phase.tint).frame(width: 6, height: 6).accessibilityHidden(true)
            Text(verbatim: job.configuration.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
            phase.subtitle(command: job.configuration.command).font(.system(size: 11)).foregroundStyle(phase.tint)
                .lineLimit(1)
            Spacer(minLength: 4)
            IconButton(symbol: "doc.on.doc", help: "Copy Output") { copyOutput() }
            IconButton(symbol: "arrow.clockwise", help: "Restart") { restart(job) }
                .disabled(!(phase.isRunning || phase.hasEnded) || model.demoMode)
            if phase.isRunning {
                IconButton(symbol: "stop.circle", help: jobStopLabel, tint: DS.red) {
                    model.requestJobStop(job, from: surface)
                }.disabled(model.demoMode)
            } else if phase == .unresponsive {
                IconButton(symbol: "xmark.octagon", help: "Force Stop…", tint: DS.red) {
                    model.requestForceStop(job, from: surface)
                }.disabled(model.demoMode)
            }
        }.padding(.horizontal, 16)
    }

    private var newOutputButton: some View {
        Button {
            feed.scrollToEnd?()
        } label: {
            Label("New output", systemImage: "arrow.down").font(.system(size: 11, weight: .medium))
                .foregroundStyle(DS.text).padding(.horizontal, 12).padding(.vertical, 7)
                .background(DS.surface, in: Capsule())
                .overlay(Capsule().strokeBorder(DS.line, lineWidth: 0.5))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain).padding(.bottom, 10)
    }

    /// The whole retained output, not only what the view still holds.
    private func copyOutput() {
        let animate = PanelMotion.isPointerEvent
        Task {
            let output = await model.launcher.output(for: jobID)
            model.copy(output, message: "Output copied", animateFeedback: animate)
        }
    }

    private func restart(_ job: LaunchRecord) {
        model.presentationSurface = surface
        model.restartJob(job)
    }
}

/// A saved action or a launched slot. The leading glyph and the subtitle show its phase; at most two controls trail,
/// after a saved action's edit button, which hover or keyboard focus reveals.
private struct LaunchRowView: View {
    @Bindable var model: MonitorModel
    let row: LaunchRow
    let surface: MonitorSurface
    @State private var hovered = false
    @FocusState private var removeFocused: Bool
    @FocusState private var editFocused: Bool

    private var phase: LaunchPhase { LaunchPhase(model: model, id: row.id, job: row.job) }
    /// The demo lists the real saved actions, so changing one there would change the user's settings.
    private var canEdit: Bool { row.isSaved && !model.demoMode && !model.isQuitting }

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
                // Only a saved action has no slot before its first start. Not disabled in the demo, which would dim
                // the row; presentEdit ignores the click there.
                Button {
                    edit()
                } label: {
                    labels
                }.buttonStyle(.plain).help("Edit")
            }
            if row.isSaved {
                let revealed = hovered || editFocused
                IconButton(symbol: "pencil", help: "Edit") { edit() }
                    .focused($editFocused).opacity(revealed ? 1 : 0).allowsHitTesting(revealed)
                    .disabled(!canEdit)
            }
            controls
        }
        .onHover { hovered = $0 }
        .contextMenu { menu }
    }

    private var labels: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(verbatim: row.configuration.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
            phase.subtitle(command: row.configuration.command)
                .font(.system(size: 11, design: phase == .idle ? .monospaced : .default))
                .foregroundStyle(phase.tint).lineLimit(1)
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
            IconButton(symbol: "stop.circle", help: jobStopLabel, tint: DS.red) { requestStop() }
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
            Button("Restart") { restart() }.disabled(!phase.isRunning || model.demoMode)
            Button(role: .destructive) {
                requestStop()
            } label: {
                Text(jobStopLabel)
            }.disabled(!phase.isRunning || model.demoMode)
        }
        Divider()
        if row.isSaved {
            Button("Edit…") { edit() }.disabled(!canEdit)
        }
        Button("Copy Command") { model.copy(row.configuration.command) }
        if row.isSaved {
            Button("Delete…", role: .destructive) {
                model.requestActionDeletion(row.configuration, from: surface)
            }.disabled(!canEdit)
        } else {
            Button("Remove from List", role: .destructive) { remove() }
                .disabled(row.job?.state.isActive != false || model.demoMode)
        }
    }

    private func start() {
        model.presentationSurface = surface
        model.run(row.configuration, save: false)
    }

    private func edit() {
        model.presentEdit(row.configuration, from: surface)
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

/// Creates an action and starts it, or edits a saved one. An edit applies from the next start, so a running service
/// keeps its run.
struct LaunchForm: View {
    private enum Field: Hashable { case name, command, directory }
    @Bindable var model: MonitorModel
    let request: LaunchFormRequest
    @State private var name: String
    @State private var command: String
    @State private var directory: String
    @State private var save = true
    @State private var validation: String?
    @State private var startedID: UUID?
    @FocusState private var focusedField: Field?
    private let suggestedName: String?

    init(model: MonitorModel, request: LaunchFormRequest) {
        self.model = model
        self.request = request
        switch request.mode {
        case .create(let draft):
            _name = State(initialValue: draft.name)
            _command = State(initialValue: draft.command)
            _directory = State(initialValue: draft.directory)
            suggestedName = draft.suggestedName
        case .edit(let configuration):
            _name = State(initialValue: configuration.name)
            _command = State(initialValue: configuration.command)
            _directory = State(initialValue: configuration.directory)
            suggestedName = nil
        }
    }

    private var editing: LaunchConfiguration? {
        if case .edit(let configuration) = request.mode { return configuration }
        return nil
    }
    private var title: LocalizedStringResource { editing == nil ? "New Action" : "Edit Action" }
    private var isIncomplete: Bool { name.isEmpty || command.isEmpty || directory.isEmpty }
    /// The project folder's name, when the form starts in one, is the example.
    private var namePlaceholder: String {
        guard let suggestedName else {
            return String(localized: "For example: Frontend", comment: "Placeholder of a new action's name")
        }
        return String(
            localized: "For example: \(suggestedName)",
            comment: "Placeholder of a new action's name; the argument is its project folder's name")
    }
    private var isRunning: Bool {
        guard let editing else { return false }
        return model.launches.contains { $0.id == editing.id && $0.state.isActive }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack {
                Text(title).font(.system(size: 17, weight: .medium))
                Spacer()
                IconButton(symbol: "xmark", help: "Schließen") { model.dismissPanelDialog() }
            }
            field("NAME", placeholder: namePlaceholder, value: $name, focus: .name)
            field("COMMAND", placeholder: "npm run dev", value: $command, focus: .command, monospaced: true)
            VStack(alignment: .leading, spacing: 9) {
                Text("PROJECT FOLDER").overline()
                HStack(spacing: 8) {
                    TextField("/Pfad/zum/Projekt", text: $directory).font(.system(size: 12, design: .monospaced))
                        .textFieldStyle(.plain)
                        .focused($focusedField, equals: .directory)
                        .padding(11).background(DS.background, in: RoundedRectangle(cornerRadius: 8))
                    Button("Choose…") { chooseDirectory() }.buttonStyle(QuietButton())
                }
            }
            if editing == nil {
                Toggle("Save as action", isOn: $save).toggleStyle(.checkbox).font(.system(size: 12))
            } else if isRunning {
                Label("Currently running. Changes apply from the next start.", systemImage: "info.circle")
                    .font(.system(size: 12)).foregroundStyle(DS.accent)
            }
            Text("Runs in zsh with your shell's environment variables. Aliases aren't available.")
                .font(.system(size: 11)).foregroundStyle(DS.muted).lineSpacing(4)
            if let validation {
                Label(validation, systemImage: "exclamationmark.circle").font(.system(size: 11)).foregroundStyle(
                    DS.orange)
            }
            footer
        }.padding(24).frame(width: DS.panelWidth).background(PanelGlass())
            .task { focusedField = .name }
    }

    private var footer: some View {
        HStack {
            if let editing {
                // The confirmation replaces the form.
                Button("Delete…", role: .destructive) {
                    model.requestActionDeletion(editing, from: model.presentationSurface)
                }.buttonStyle(QuietButton(tint: DS.red)).disabled(model.demoMode || model.isQuitting)
            } else if let startedID, model.loadingShellEnvironment.contains(startedID) {
                Text("Loading shell environment…").font(.system(size: 11)).foregroundStyle(DS.muted)
            }
            Spacer()
            Button("Cancel") { model.dismissPanelDialog() }.buttonStyle(QuietButton()).keyboardShortcut(.cancelAction)
            if let editing {
                Button("Save") { saveEdit(of: editing) }.buttonStyle(AccentButton()).keyboardShortcut(.defaultAction)
                    .disabled(isIncomplete || model.demoMode)
            } else {
                Button {
                    start()
                } label: {
                    Label("Start", systemImage: "play.fill")
                }.buttonStyle(AccentButton()).keyboardShortcut(.defaultAction)
                    .disabled(isIncomplete || model.demoMode || model.isLaunching)
            }
        }
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

    /// Opens in the folder typed so far, else in the folder of the last start.
    private func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        let start =
            LaunchDraft.projectDirectory(of: NSString(string: directory).expandingTildeInPath)
            ?? LaunchDraft.projectDirectory(of: model.preferences.lastLaunchDirectory)
        if let start { panel.directoryURL = URL(fileURLWithPath: start, isDirectory: true) }
        if panel.runModal() == .OK, let url = panel.url { directory = url.path }
    }

    /// The fields as a configuration; an edit keeps the action's id, so its slot and output stay its own.
    private func enteredConfiguration(id: UUID = UUID()) -> LaunchConfiguration {
        LaunchConfiguration(
            id: id, name: name.trimmingCharacters(in: .whitespaces), command: command,
            directory: NSString(string: directory).expandingTildeInPath)
    }

    private func start() {
        let configuration = enteredConfiguration()
        do {
            try model.validateAction(configuration, saving: save)
            startedID = configuration.id
            model.run(configuration, save: save, fromForm: true)
        } catch { validation = error.localizedDescription }
    }

    private func saveEdit(of original: LaunchConfiguration) {
        do { try model.saveAction(enteredConfiguration(id: original.id)) } catch {
            validation = error.localizedDescription
        }
    }
}

/// Return never confirms it: deleting takes a deliberate click.
struct ActionDeleteConfirmation: View {
    @Bindable var model: MonitorModel
    let configuration: LaunchConfiguration
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Delete “\(configuration.name)”?").font(.system(size: 17, weight: .medium))
            Text("The saved action is removed. A running service keeps running.")
                .font(.system(size: 12)).foregroundStyle(DS.muted).lineSpacing(3)
            HStack {
                Spacer()
                Button("Cancel") { model.dismissPanelDialog() }.buttonStyle(QuietButton())
                    .keyboardShortcut(.cancelAction)
                Button("Delete", role: .destructive) {
                    model.dismissPanelDialog()
                    model.deleteAction(configuration)
                }.buttonStyle(QuietButton(tint: DS.red))
            }
        }.padding(24).frame(width: DS.panelWidth).background(PanelGlass())
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
