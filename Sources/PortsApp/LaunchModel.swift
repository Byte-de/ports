import Foundation
import PortsCore
import PortsFeatures

extension MonitorModel {
    /// Launched services are inert in the demo and once a quit has begun.
    private var acceptsJobActions: Bool { !demoMode && !isQuitting }

    /// From here on the quit stops every job and its panel shows what remains, so job confirmations close, and job
    /// actions still in flight report neither errors nor a job that isn't responding.
    func beginQuit() {
        isQuitting = true
        pendingJobStop = nil
        pendingForceStop = nil
    }

    func presentLaunch(from surface: MonitorSurface) {
        guard acceptsJobActions, !hasPanelDialog else { return }
        presentationSurface = PanelWindowCoordinator.shared.dialogSurface(from: surface)
        dialogUsesMotion = PanelMotion.isPointerEvent
        showLaunchForm = true
    }

    func requestJobStop(_ job: LaunchRecord, from surface: MonitorSurface) {
        guard acceptsJobActions, !hasPanelDialog, !busyJobs.contains(job.id) else { return }
        presentationSurface = PanelWindowCoordinator.shared.dialogSurface(from: surface)
        dialogUsesMotion = PanelMotion.isPointerEvent
        pendingJobStop = job
    }

    /// Only offered once a stop timed out. A restart that timed out restarts after the confirmed force stop.
    func requestForceStop(_ job: LaunchRecord, from surface: MonitorSurface) {
        guard acceptsJobActions, !hasPanelDialog, !busyJobs.contains(job.id) else { return }
        presentationSurface = PanelWindowCoordinator.shared.dialogSurface(from: surface)
        dialogUsesMotion = PanelMotion.isPointerEvent
        pendingForceStop = PendingForceStop(job: job, restartAfter: restartAfterForce.contains(job.id))
    }

    func run(_ configuration: LaunchConfiguration, save: Bool, fromForm: Bool = false) {
        guard acceptsJobActions, !isLaunching else { return }
        isLaunching = true
        if fromForm { pendingFormLaunch = configuration.id }
        Task {
            defer {
                isLaunching = false
                pendingFormLaunch = nil
            }
            do {
                await loadShellEnvironment(for: configuration.id)
                // Reading the environment can take seconds, and the form stays open and can be dismissed meanwhile.
                guard !fromForm || pendingFormLaunch == configuration.id else {
                    PortsLog.launch.info("Start cancelled while the shell environment loaded")
                    return
                }
                let id = try await launcher.start(configuration)
                if save && !preferences.launchConfigurations.contains(where: { $0.id == configuration.id }) {
                    preferences.launchConfigurations.append(configuration)
                    savePreferences()
                }
                record("\(configuration.name) gestartet", detail: configuration.directory, symbol: "play.circle")
                // After the entry, so a command that fails at once is reported after its start.
                await reloadLaunches()
                logJobID = id
                showingLogs = true
                showLaunchForm = false
                section = .actions
                search = ""
                showingDetails = false
                await refresh()
            } catch { reportUnlessQuitting(error, as: .start) }
        }
    }

    func stopJob(_ job: LaunchRecord) {
        guard acceptsJobActions, busyJobs.insert(job.id).inserted else { return }
        Task {
            if await endedBeforeAction(job) { return }
            defer { busyJobs.remove(job.id) }
            let name = job.configuration.name
            do {
                let outcome = try await launcher.stop(job.id)
                await reloadLaunches()
                if outcome == .stopped {
                    let message: LocalizedStringResource = "“\(name)” stopped"
                    record(message, detail: job.configuration.directory, symbol: "stop.circle")
                    notify(message)
                } else if !isQuitting {
                    let message: LocalizedStringResource = "“\(name)” isn't responding"
                    record(message, detail: job.configuration.directory, symbol: "exclamationmark.triangle")
                    notify(message)
                }
                await refresh()
            } catch {
                await reloadLaunches()
                reportUnlessQuitting(error, as: .stop)
            }
        }
    }

    func restartJob(_ job: LaunchRecord) {
        guard acceptsJobActions, busyJobs.insert(job.id).inserted else { return }
        Task {
            defer { busyJobs.remove(job.id) }
            await restartSlot(of: job)
            await refresh()
        }
    }

    /// Kills only the run the user confirmed, so a run that started since is never touched.
    func forceStop(_ pending: PendingForceStop) {
        let job = pending.job
        guard acceptsJobActions, busyJobs.insert(job.id).inserted else { return }
        Task {
            if await endedBeforeAction(job) { return }
            defer { busyJobs.remove(job.id) }
            let name = job.configuration.name
            do {
                let outcome = try await launcher.forceStop(job.id, run: job.runID)
                await reloadLaunches()
                guard outcome == .stopped else { throw LaunchError.couldNotStop(name) }
                restartAfterForce.remove(job.id)
                let message: LocalizedStringResource = "“\(name)” force stopped"
                record(message, detail: job.configuration.directory, symbol: "xmark.octagon")
                notify(message)
            } catch {
                await reloadLaunches()
                reportUnlessQuitting(error, as: .stop)
                return
            }
            if pending.restartAfter && acceptsJobActions { await restartSlot(of: job) }
            await refresh()
        }
    }

    func removeJob(_ job: LaunchRecord) {
        guard acceptsJobActions, !busyJobs.contains(job.id) else { return }
        Task {
            guard await launcher.remove(job.id) else { return }
            await reloadLaunches()
        }
    }

    func removeFinishedJobs() {
        guard acceptsJobActions else { return }
        Task {
            guard await !launcher.removeFinished().isEmpty else { return }
            await reloadLaunches()
        }
    }

    /// Reads the slots and records how runs ended since the last read. It assigns only on change, so views redraw and
    /// each end is reported once.
    func reloadLaunches() async {
        let next = await launcher.records()
        // No automatic restart once a timed-out job has ended on its own. Checked on every read, because a restart
        // can mark a job that an earlier read already saw end.
        let active = Set(next.filter(\.state.isActive).map(\.id))
        if !restartAfterForce.isSubset(of: active) { restartAfterForce.formIntersection(active) }
        // Read after the await: overlapping reloads then each compare with the newest state, so no end repeats.
        let previous = launches
        guard next != previous else { return }
        launches = next
        if let shown = logJobID, !next.contains(where: { $0.id == shown }) {
            logJobID = nil
            showingLogs = false
            logs = ""
        }
        // Like the log, a confirmation closes with its run, so it never reports a stop that didn't happen.
        if let job = pendingJobStop, !LaunchListing.isLive(job, in: next) { pendingJobStop = nil }
        if let job = pendingForceStop?.job, !LaunchListing.isLive(job, in: next) { pendingForceStop = nil }
        // A stop reports a run that ended during it; a restart's new run is reported like any other.
        let acting = busyJobs.subtracting(restartingJobs)
        for event in LaunchListing.transitions(old: previous, new: next, userInitiated: acting) {
            switch event {
            case .exited(let job):
                record(
                    "“\(job.configuration.name)” exited", detail: job.configuration.directory,
                    symbol: "checkmark.circle")
            case .failed(let job, let userInitiated):
                let message: LocalizedStringResource = "“\(job.configuration.name)” failed · exit \(job.exitCode ?? -1)"
                record(message, detail: job.configuration.directory, symbol: "xmark.circle")
                if !userInitiated { notify(message) }
            }
        }
    }

    /// A job action that fails because a quit began, such as a start the launcher refuses, is logged only.
    private func reportUnlessQuitting(_ error: any Error, as context: ErrorContext) {
        guard isQuitting else { return report(error, as: context) }
        PortsLog.launch.info(
            "Suppressed \(context.logKey, privacy: .public) error during quit: \(error.localizedDescription, privacy: .private)"
        )
    }

    /// The launcher calls a run that already ended stopped, and a run can end after its dialog opened and before a read
    /// shows it, as when its last subprocess exits after the root. Reads the slots without the job marked busy, so
    /// that end is reported like any other.
    private func endedBeforeAction(_ job: LaunchRecord) async -> Bool {
        guard await launcher.status(for: job.id)?.isActive != true else { return false }
        busyJobs.remove(job.id)
        await reloadLaunches()
        return true
    }

    /// Runs end without any action in the app, so every exit reads the slots again. Called once, because the stream
    /// has a single consumer.
    func startLaunchObserver() {
        guard launchObserver == nil else { return }
        let changes = launcher.changes
        launchObserver = Task { [weak self] in
            for await _ in changes {
                guard let self else { return }
                await self.reloadLaunches()
            }
        }
    }

    /// The slot keeps its id, so logJobID stays valid. A saved action restarts as currently saved.
    private func restartSlot(of job: LaunchRecord) async {
        restartingJobs.insert(job.id)
        defer { restartingJobs.remove(job.id) }
        let saved = preferences.launchConfigurations.first { $0.id == job.id }
        let configuration = saved ?? job.configuration
        do {
            await loadShellEnvironment(for: job.id)
            if try await launcher.restart(job.id, using: saved) == .stopped {
                let message: LocalizedStringResource = "“\(configuration.name)” restarted"
                record(message, detail: configuration.directory, symbol: "arrow.clockwise")
                notify(message)
            } else {
                // A stop that timed out never escalates on its own; the user can force stop, which then restarts.
                restartAfterForce.insert(job.id)
                if !isQuitting {
                    let message: LocalizedStringResource =
                        "“\(configuration.name)” isn't responding and wasn't restarted."
                    record(message, detail: configuration.directory, symbol: "exclamationmark.triangle")
                    notify(message)
                }
            }
        } catch { reportUnlessQuitting(error, as: .start) }
        // After the outcome, so a new run that failed at once has the last word.
        await reloadLaunches()
    }

    /// The first start of a session runs the user's shell to read its environment, which can take seconds, so the row
    /// says so meanwhile. Later starts reuse the result until a shell startup file changes.
    private func loadShellEnvironment(for id: UUID) async {
        guard await !launcher.isShellEnvironmentReady else { return }
        loadingShellEnvironment.insert(id)
        defer { loadingShellEnvironment.remove(id) }
        await launcher.prepareShellEnvironment()
    }

    func showLogs(_ job: LaunchRecord) {
        logJobID = job.id
        showingLogs = true
        Task { logs = await launcher.output(for: job.id) }
    }
}
