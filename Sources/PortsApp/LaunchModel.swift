import Foundation
import PortsCore

extension MonitorModel {
    func presentLaunch(from surface: MonitorSurface) {
        guard !demoMode, !hasPanelDialog else { return }
        presentationSurface = PanelWindowCoordinator.shared.dialogSurface(from: surface)
        dialogUsesMotion = PanelMotion.isPointerEvent
        showLaunchForm = true
    }

    func requestJobStop(_ job: LaunchRecord, from surface: MonitorSurface) {
        guard !demoMode, !hasPanelDialog else { return }
        presentationSurface = PanelWindowCoordinator.shared.dialogSurface(from: surface)
        dialogUsesMotion = PanelMotion.isPointerEvent
        pendingJobStop = job
    }

    func run(_ configuration: LaunchConfiguration, save: Bool) {
        guard !demoMode, !isLaunching else { return }
        isLaunching = true
        Task {
            defer { isLaunching = false }
            do {
                let id = try await launcher.start(configuration)
                if save && !preferences.launchConfigurations.contains(where: { $0.id == configuration.id }) {
                    preferences.launchConfigurations.append(configuration)
                    savePreferences()
                }
                launches = await launcher.records()
                logJobID = id
                showingLogs = true
                record("\(configuration.name) gestartet", detail: configuration.directory, symbol: "play.circle")
                showLaunchForm = false
                section = .actions
                search = ""
                showingDetails = false
                await refresh()
            } catch { report(error, as: .start) }
        }
    }

    func manageJob(_ job: LaunchRecord, restart: Bool) {
        guard !demoMode, busyJobs.insert(job.id).inserted else { return }
        Task {
            defer { busyJobs.remove(job.id) }
            do {
                if restart { logJobID = try await launcher.restart(job.id) } else { try await launcher.stop(job.id) }
                launches = await launcher.records()
                let name = job.configuration.name
                record(
                    restart ? "\(name) neu gestartet" : "\(name) gestoppt", detail: String(localized: "Startaktion"),
                    symbol: "arrow.clockwise")
                await refresh()
            } catch { report(error, as: restart ? .start : .stop) }
        }
    }

    func showLogs(_ job: LaunchRecord) {
        logJobID = job.id
        showingLogs = true
        Task { logs = await launcher.output(for: job.id) }
    }
}
