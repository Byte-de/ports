import AppKit
import Observation
import PortsCore
import ServiceManagement

/// Whether macOS opens the app at login.
/// System-owned state; never mirrored into preferences so System Settings stays authoritative.
@MainActor @Observable
final class LoginItem {
    enum Availability {
        case available
        /// `swift run`: there is no app bundle to register.
        case notBundled
        /// Opened from a disk image or translocated by Gatekeeper: macOS would register a copy that goes away.
        case needsMove
    }

    static let shared = LoginItem()
    let availability: Availability
    private(set) var status: SMAppService.Status = .notRegistered
    @ObservationIgnored private var activationObserver: (any NSObjectProtocol)?

    private init() {
        availability = Self.availability(of: Bundle.main.bundleURL)
        refresh()
        // The user may have changed the login item in System Settings while the app was in the background.
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    var isAvailable: Bool { availability == .available }
    /// A registration awaiting approval counts as on: the user chose it. `.notFound` means off, because macOS also
    /// reports it for apps that were never registered.
    var isEnabled: Bool { status == .enabled || status == .requiresApproval }
    var requiresApproval: Bool { status == .requiresApproval }

    func refresh() {
        guard availability != .notBundled else { return }
        status = SMAppService.mainApp.status
    }

    func setEnabled(_ enabled: Bool) throws {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            refresh()
            PortsLog.lifecycle.notice("Login item \(enabled ? "registered" : "unregistered", privacy: .public)")
        } catch {
            refresh()
            let change = enabled ? "registration" : "removal"
            PortsLog.lifecycle.error(
                "Login item \(change, privacy: .public) failed: \(error.localizedDescription, privacy: .private)")
            // Already registered, already removed, or turned off in System Settings (now awaiting approval, which
            // the row explains): the system is where the user asked, so an alert would contradict the switch.
            guard isEnabled == enabled else { throw error }
        }
    }

    func openSystemSettings() { SMAppService.openSystemSettingsLoginItems() }

    private static func availability(of bundle: URL) -> Availability {
        guard bundle.pathExtension == "app" else { return .notBundled }
        let path = bundle.path(percentEncoded: false)
        return path.contains("/AppTranslocation/") || path.hasPrefix("/Volumes/") ? .needsMove : .available
    }
}
