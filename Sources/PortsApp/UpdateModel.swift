import Foundation
import PortsCore
import PortsFeatures

/// The latest check of this session, manual or weekly. What a check finds is also saved, so the hint survives a
/// relaunch without asking GitHub again; only a manual check ever shows that it failed.
enum UpdateStatus {
    case idle, checking, current
    case available(AvailableRelease)
    case failed
}

extension MonitorModel {
    /// Asks GitHub once, never twice at the same time. Nothing but the request leaves the Mac, and nothing installs.
    func runUpdateCheck(automatic: Bool) async {
        guard !updateCheckInFlight else { return }
        updateCheckInFlight = true
        defer { updateCheckInFlight = false }
        PortsLog.update.info("Update check started (\(automatic ? "scheduled" : "manual", privacy: .public))")
        let previous = updateStatus
        updateStatus = .checking
        // Its own task, so restarting the schedule never aborts a request that is already on its way.
        let check = Task { try await ReleaseChecker().check(currentVersion: AppInfo.version) }
        do {
            let release = try await check.value
            // nil once nothing newer than this version exists, which also drops a release that was withdrawn.
            persistQuietly {
                $0.lastUpdateCheck = Date()
                $0.latestKnownVersion = release?.version.string
            }
            updateStatus = if let release { .available(release) } else { .current }
        } catch {
            guard automatic else {
                updateStatus = .failed
                return
            }
            // ReleaseChecker logged the cause. The check stays due, so the next tick tries again.
            PortsLog.update.info("Scheduled update check failed silently")
            updateStatus = previous
        }
    }

    /// Looks at the schedule after `initialDelay` and then every tick; it asks GitHub only while the weekly check is
    /// on and due. Starting again replaces the running schedule.
    func startAutomaticUpdateChecks(initialDelay: Duration = UpdateSchedule.launchDelay) {
        automaticUpdateTask?.cancel()
        automaticUpdateTask = Task { [weak self] in
            try? await Task.sleep(for: initialDelay)
            while !Task.isCancelled {
                guard let self else { return }
                if self.preferences.checksForUpdatesAutomatically,
                    UpdateSchedule.isDue(lastCheck: self.preferences.lastUpdateCheck, now: Date())
                {
                    await self.runUpdateCheck(automatic: true)
                }
                try? await Task.sleep(for: UpdateSchedule.tick)
            }
        }
    }

    /// Turning the weekly check on checks at once when one is due, instead of at the next tick.
    func setAutomaticUpdateChecks(_ enabled: Bool) {
        guard enabled != preferences.checksForUpdatesAutomatically,
            commitPreferences({ $0.checksForUpdatesAutomatically = enabled })
        else { return }
        PortsLog.update.notice("Weekly update check \(enabled ? "on" : "off", privacy: .public)")
        if enabled { startAutomaticUpdateChecks(initialDelay: .zero) }
    }

    /// What a check in this session found, otherwise what an earlier check saved.
    private var latestKnownVersion: String? {
        switch updateStatus {
        case .available(let release): release.version.string
        case .current: nil
        case .idle, .checking, .failed: preferences.latestKnownVersion
        }
    }

    /// The newest release when it is newer than this version, also after its hint was dismissed.
    var latestAvailableRelease: AvailableRelease? {
        UpdateSchedule.pendingRelease(latestKnown: latestKnownVersion, dismissed: nil, current: AppInfo.version)
            .map(AvailableRelease.init(version:))
    }

    /// The dot on the settings gear: a newer release whose hint wasn't dismissed.
    var showsUpdateBadge: Bool {
        UpdateSchedule.pendingRelease(
            latestKnown: latestKnownVersion, dismissed: preferences.dismissedUpdateVersion, current: AppInfo.version)
            != nil
    }

    /// Hides the dot for this release only; a newer one shows it again.
    func dismissUpdateHint() {
        guard let release = latestAvailableRelease else { return }
        commitPreferences { $0.dismissedUpdateVersion = release.version.string }
    }
}
