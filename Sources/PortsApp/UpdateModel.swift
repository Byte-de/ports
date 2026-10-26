import AppKit
import PortsCore

/// Transient UI state; checking never persists identifiers or starts a background timer.
enum UpdateStatus {
    case idle, checking, current
    case available(AvailableRelease)
    case failed(String)
}

extension MonitorModel {
    func checkForUpdates() {
        if case .checking = updateStatus { return }
        updateStatus = .checking
        Task {
            do {
                if let release = try await ReleaseChecker().check(currentVersion: AppInfo.version) {
                    updateStatus = .available(release)
                } else {
                    updateStatus = .current
                }
            } catch {
                updateStatus = .failed("Die Update-Prüfung ist fehlgeschlagen. Bitte versuche es später erneut.")
            }
        }
    }
}
