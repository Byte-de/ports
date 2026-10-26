import AppKit
import Observation
import PortsCore
import PortsFeatures
import SwiftUI

enum NavigationSection: String, CaseIterable, Identifiable {
    case overview, agents, servers, projects, actions, activity, settings
    var id: String { rawValue }
    var title: LocalizedStringResource {
        switch self {
        case .overview: "Prozesse"
        case .agents: "Agenten"
        case .servers: "Server"
        case .projects: "Projekte"
        case .actions: "Aktionen"
        case .activity: "Aktivität"
        case .settings: "Einstellungen"
        }
    }
    var symbol: String {
        switch self {
        case .overview: "rectangle.stack"
        case .agents: "sparkles"
        case .servers: "server.rack"
        case .projects: "folder"
        case .actions: "bolt"
        case .activity: "clock.arrow.circlepath"
        case .settings: "slider.horizontal.3"
        }
    }
}

enum DisplayMode: String, CaseIterable { case list, board }
struct ActivityEntry: Identifiable {
    let id = UUID()
    let date: Date
    let title: String
    let detail: String
    let symbol: String
}
struct PendingAction: Identifiable {
    let id = UUID()
    let service: ServiceRecord
    let action: ProcessAction
}

/// Settings folders of earlier app names, newest first: pre-release builds were called Byte Relay, the internal
/// prototype DevScope. The case label goes to the log.
private enum LegacyPreferences: String, CaseIterable {
    case byteRelay, devScope
    var url: URL {
        let folder = self == .byteRelay ? "Byte Relay" : "DevScope"
        return URL.applicationSupportDirectory.appending(path: "\(folder)/preferences.json")
    }
}

@MainActor @Observable
final class MonitorModel {
    var section: NavigationSection = .servers
    var displayMode: DisplayMode = .list
    var navigationUsesMotion = false
    var search = ""
    var selectedID: ProcessIdentity?
    var showingDetails = false
    var showingLogs = false
    var presentationSurface: MonitorSurface = .window
    var snapshot = ScanSnapshot(services: [], processCount: 0)
    var hasScanned = false
    var isScanning = false
    var isLaunching = false
    var isMonitoring = true
    var demoMode = false
    var panelError: PanelError?
    /// Shown inline instead of an alert, because scans repeat every few seconds.
    var detectionIssue: String?
    var toast: String?
    var toastUsesMotion = false
    var dialogUsesMotion = false
    var pendingAction: PendingAction?
    var pendingJobStop: LaunchRecord?
    var pendingShare: TunnelTarget?
    var updateStatus: UpdateStatus = .idle
    var showLaunchForm = false
    var onboardingSession: UUID?
    var logJobID: UUID?
    var logs = ""
    var launches: [LaunchRecord] = []
    var activity: [ActivityEntry] = []
    var preferences: AppPreferences
    var histories: [ProcessIdentity: [Double]] = [:]
    var busyIDs: Set<ProcessIdentity> = []
    var busyJobs: Set<UUID> = []
    var tunnelRecords: [TunnelRecord] = []
    var sharingBusy: Set<TunnelKey> = []
    var isQuitting = false
    var isSwitchingDemo = false
    @ObservationIgnored let tunnels = CloudflareTunnelManager(
        client: Bundle.main.bundleURL.appending(path: "Contents/Helpers/cloudflared"),
        runner: Bundle.main.bundleURL.appending(path: "Contents/Helpers/ports-tunnel-runner"))
    @ObservationIgnored var tunnelTask: Task<Void, Never>?
    @ObservationIgnored var pendingTunnelCopy: Set<TunnelKey> = []
    @ObservationIgnored private let scanner = ProcessScanner()
    @ObservationIgnored private let controller = ProcessController()
    @ObservationIgnored let launcher = LaunchManager()
    @ObservationIgnored private let repository: PreferencesRepository
    @ObservationIgnored private var persistenceAvailable = true
    @ObservationIgnored private var scanGeneration = 0
    @ObservationIgnored private var loopTask: Task<Void, Never>?
    @ObservationIgnored private var toastTask: Task<Void, Never>?
    @ObservationIgnored private(set) var revealWindow: (() -> Void)?
    @ObservationIgnored private var windowRevealPending = false

    init() {
        let arguments = ProcessInfo.processInfo.arguments
        let directory: URL
        if let index = arguments.firstIndex(of: "--state-directory"), arguments.indices.contains(index + 1) {
            directory = URL(fileURLWithPath: arguments[index + 1], isDirectory: true)
        } else {
            directory = URL.applicationSupportDirectory.appending(path: "Byte Ports", directoryHint: .isDirectory)
        }
        // Migrate from the newest earlier name that still has settings.
        let legacy =
            arguments.contains("--state-directory")
            ? nil : LegacyPreferences.allCases.first { FileManager.default.fileExists(atPath: $0.url.path) }
        repository = PreferencesRepository(url: directory.appending(path: "preferences.json"), legacyURL: legacy?.url)
        let migrates = legacy != nil && !FileManager.default.fileExists(atPath: repository.url.path)
        do {
            preferences = try repository.load()
            if migrates, let legacy {
                PortsLog.persistence.notice("Migrated preferences from \(legacy.rawValue, privacy: .public)")
            }
        } catch {
            preferences = AppPreferences()
            persistenceAvailable = false
            PortsLog.persistence.error(
                "Preferences unreadable, saving disabled: \(error.localizedDescription, privacy: .private)")
            report("The existing file is kept unchanged. \(error.localizedDescription)", as: .preferencesLoad)
        }
        if arguments.contains("--demo") {
            demoMode = true
            snapshot = DemoData.snapshot
            hasScanned = true
            selectedID = snapshot.services.first?.id
        }
        if arguments.contains("--onboarding") || (!preferences.hasCompletedOnboarding && !demoMode) {
            onboardingSession = UUID()
        }
    }

    var services: [ServiceRecord] { snapshot.services }
    var selected: ServiceRecord? { services.first { $0.id == selectedID } }
    var visibleUniverse: [ServiceRecord] {
        ServiceListing.visible(services, filter: .all, search: "", showsListeners: preferences.showOtherListeners)
    }
    var counts: ServiceCounts { ServiceCounts(visibleUniverse) }

    /// The menu bar label and the main window both bind the opener, so a hidden menu bar item cannot leave the app
    /// without one. A reveal requested before either appeared runs on the first binding.
    func bindWindowOpener(_ open: @escaping () -> Void) {
        revealWindow = {
            guard PanelWindowCoordinator.shared.prepareMainWindow() else { return }
            open()
            NSApp.activate()
            PanelWindowCoordinator.shared.bringMainWindowForward()
        }
        if windowRevealPending {
            windowRevealPending = false
            revealWindow?()
        }
    }

    func showMainWindow() {
        guard let revealWindow else {
            windowRevealPending = true
            PortsLog.lifecycle.error("Main window requested before any view bound the window opener")
            return
        }
        revealWindow()
    }

    var hasBlockingPanelDialog: Bool {
        showLaunchForm || pendingAction != nil || pendingJobStop != nil || pendingShare != nil
    }
    var hasPanelDialog: Bool { hasBlockingPanelDialog || panelError != nil }

    func report(_ error: any Error, as context: ErrorContext) {
        present(error.localizedDescription, as: context)
    }

    func report(_ message: LocalizedStringResource, as context: ErrorContext) {
        present(String(localized: message), as: context)
    }

    private func present(_ message: String, as context: ErrorContext) {
        PortsLog.ui.error("Presented error \(context.logKey, privacy: .public): \(message, privacy: .private)")
        panelError = PanelError(context: context, message: message)
    }

    func dismissPanelDialog() {
        dialogUsesMotion = PanelMotion.isPointerEvent
        showLaunchForm = false
        pendingAction = nil
        pendingJobStop = nil
        pendingShare = nil
    }

    func confirmPublicSharing() {
        guard let target = pendingShare, !isQuitting, !demoMode else { return }
        guard persistenceAvailable else {
            report("The settings can't be read, so sharing wasn't started.", as: .share)
            return
        }
        do {
            var next = preferences
            next.hasAcknowledgedPublicSharing = true
            try writePreferences(next)
            preferences = next
            dismissPanelDialog()
            share(target, from: presentationSurface)
        } catch { report(error, as: .share) }
    }
    var filteredServices: [ServiceRecord] {
        filteredServices(in: section)
    }

    func filteredServices(in section: NavigationSection) -> [ServiceRecord] {
        let filter: ServiceFilter =
            switch section {
            case .agents: .agents
            case .servers: .servers
            default: .all
            }
        return ServiceListing.visible(
            services, filter: filter, search: search, showsListeners: preferences.showOtherListeners)
    }

    func startMonitoring() {
        guard loopTask == nil else { return }
        startTunnelMonitoring()
        loopTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if self.isMonitoring && !self.demoMode { await self.refresh() }
                do { try await Task.sleep(for: .seconds(self.preferences.refreshInterval)) } catch { return }
            }
        }
    }

    func refresh() async {
        guard !isScanning, !demoMode else { return }
        isScanning = true
        let generation = scanGeneration
        defer { isScanning = false }
        do {
            #if DEBUG
                // Manual check of the inline failure line: scans fail while this file exists.
                let failureSwitch = FileManager.default.temporaryDirectory.appending(path: "ports-fail-scans")
                if FileManager.default.fileExists(atPath: failureSwitch.path) { throw MonitorError.timedOut }
            #endif
            let next = try await scanner.scan(customRules: preferences.agentRules)
            guard generation == scanGeneration, !demoMode else { return }
            detectionIssue = nil
            let previousIDs = Set(services.map(\.id))
            let nextIDs = Set(next.services.map(\.id))
            if hasScanned {
                for service in next.services where !previousIDs.contains(service.id) && service.kind != .listener {
                    record("\(service.title) erkannt", detail: service.process.projectName, symbol: "plus.circle")
                }
                // A failed listener query cannot prove that a service exited.
                if next.warning == nil {
                    for service in services where !nextIDs.contains(service.id) && service.kind != .listener {
                        record(
                            "\(service.title) nicht mehr aktiv", detail: service.process.projectName,
                            symbol: "minus.circle")
                    }
                }
            }
            snapshot = next
            hasScanned = true
            histories = histories.filter { nextIDs.contains($0.key) }
            for service in services {
                if let value = service.cpuPercent {
                    histories[service.id, default: []].append(value)
                    histories[service.id] = Array(histories[service.id, default: []].suffix(40))
                }
            }
            if !showingDetails, selectedID.map({ !nextIDs.contains($0) }) ?? true {
                selectedID = visibleUniverse.first?.id
            }
        } catch {
            PortsLog.scan.error("Scan failed: \(error.localizedDescription, privacy: .private)")
            if generation == scanGeneration && !demoMode { detectionIssue = error.localizedDescription }
        }
        if !launches.isEmpty { launches = await launcher.records() }
        if let logJobID { logs = await launcher.output(for: logJobID) }
    }

    func navigate(_ target: NavigationSection, mode: DisplayMode = .list) {
        navigationUsesMotion = PanelMotion.animatesInteraction
        section = target
        search = ""
        showingDetails = false
        showingLogs = false
        displayMode = mode
    }

    func inspect(_ service: ServiceRecord) {
        selectedID = service.id
        showingDetails = true
    }

    func presentOnboarding() {
        guard !hasPanelDialog else { return }
        presentationSurface = .window
        if onboardingSession == nil { onboardingSession = UUID() }
        revealWindow?()
    }

    func dismissOnboarding() {
        onboardingSession = nil
    }

    /// Draft choices become visible only after saving succeeds. Skipping passes
    /// no choices; closing the introduction never changes persisted preferences.
    func finishOnboarding(showNotch: Bool?, demo: Bool?, persist: Bool = true) throws {
        var next = preferences
        next.hasCompletedOnboarding = true
        if let showNotch { next.showNotch = showNotch }
        if persist {
            guard persistenceAvailable else {
                throw MonitorError.scanFailed(
                    "Die vorhandene Einstellungsdatei kann nicht gelesen werden und bleibt unverändert.")
            }
            try writePreferences(next)
        }
        preferences = next
        if !persist && !persistenceAvailable { panelError = nil }
        onboardingSession = nil
        navigate(.servers)
        if let demo, demo != demoMode { toggleDemo() }
    }

    func toggleDemo() {
        guard !isSwitchingDemo else { return }
        if !demoMode {
            isSwitchingDemo = true
            Task {
                defer { isSwitchingDemo = false }
                do {
                    try await tunnels.stopAll()
                    pendingTunnelCopy.removeAll()
                    await updateTunnels()
                    applyDemoToggle()
                } catch { report(error, as: .generic) }
            }
        } else {
            applyDemoToggle()
        }
    }

    private func applyDemoToggle() {
        demoMode.toggle()
        scanGeneration += 1
        search = ""
        histories = [:]
        selectedID = nil
        showingDetails = false
        showingLogs = false
        detectionIssue = nil
        if demoMode {
            snapshot = DemoData.snapshot
            selectedID = services.first?.id
            hasScanned = true
        } else {
            snapshot = ScanSnapshot(services: [], processCount: 0)
            hasScanned = false
            Task { await refresh() }
        }
    }

    func savePreferences() {
        guard persistenceAvailable else {
            report(
                "Saving is turned off so the unreadable settings file is kept. The README has details.",
                as: .preferencesSave)
            return
        }
        do { try writePreferences(preferences) } catch { report(error, as: .preferencesSave) }
    }

    /// Logs a failed save; callers decide whether and how to present it.
    private func writePreferences(_ next: AppPreferences) throws {
        do { try repository.save(next) } catch {
            PortsLog.persistence.error("Saving preferences failed: \(error.localizedDescription, privacy: .private)")
            throw error
        }
    }

    func canControl(_ service: ServiceRecord) -> Bool {
        !demoMode && !busyIDs.contains(service.id) && controller.isControllable(service.process)
    }

    func request(_ action: ProcessAction, service: ServiceRecord, from surface: MonitorSurface = .window) {
        guard canControl(service), !hasPanelDialog else { return }
        if action == .terminate {
            presentationSurface = PanelWindowCoordinator.shared.dialogSurface(from: surface)
            dialogUsesMotion = PanelMotion.isPointerEvent
            pendingAction = PendingAction(service: service, action: action)
        } else {
            presentationSurface = surface
            perform(action, service: service)
        }
    }

    func perform(_ action: ProcessAction, service: ServiceRecord) {
        guard canControl(service) else { return }
        busyIDs.insert(service.id)
        let controller = controller
        Task {
            defer { busyIDs.remove(service.id) }
            do {
                try await Task.detached { try controller.perform(action, on: service.process) }.value
                let entry: LocalizedStringResource
                let message: LocalizedStringResource
                switch action {
                case .pause:
                    entry = "\(service.title): pausiert"
                    message = "\(service.title) · pausiert"
                case .resume:
                    entry = "\(service.title): fortgesetzt"
                    message = "\(service.title) · fortgesetzt"
                case .terminate:
                    entry = "\(service.title): Stop angefragt"
                    message = "\(service.title) · Stop angefragt"
                }
                record(
                    entry, detail: "PID \(service.id.pid)",
                    symbol: action == .pause ? "pause.circle" : "checkmark.circle")
                notify(message)
                await refresh()
            } catch {
                report(error, as: ErrorContext(action))
                await refresh()
            }
        }
    }

    func copy(_ value: String, message: LocalizedStringResource = "Kopiert", animateFeedback: Bool? = nil) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
        notify(message, animate: animateFeedback ?? PanelMotion.isPointerEvent)
    }

    func openEndpoint(_ endpoint: ListeningEndpoint) {
        guard !demoMode, let url = endpoint.url else { return }
        if !NSWorkspace.shared.open(url) { report("The address couldn't be opened.", as: .open) }
    }

    func openDirectory(_ directory: String, terminal: Bool = false) {
        guard !demoMode else { return }
        let url = URL(fileURLWithPath: directory, isDirectory: true)
        if terminal {
            guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") else {
                report("Terminal wasn't found.", as: .open)
                return
            }
            NSWorkspace.shared.open([url], withApplicationAt: app, configuration: .init()) { [weak self] _, error in
                if let error { Task { @MainActor in self?.report(error, as: .open) } }
            }
        } else if !NSWorkspace.shared.open(url) {
            report("The project folder couldn't be opened.", as: .open)
        }
    }

    func activate(_ service: ServiceRecord) {
        guard !demoMode else { return }
        if service.isDesktopApplication, let app = NSRunningApplication(processIdentifier: service.id.pid),
            app.activate(options: [])
        {
            return
        }
        if let directory = service.process.workingDirectory {
            openDirectory(directory, terminal: true)
        }
    }

    func favorite(_ key: String) {
        if preferences.favoriteProjects.contains(key) {
            preferences.favoriteProjects.remove(key)
        } else {
            preferences.favoriteProjects.insert(key)
        }
        savePreferences()
    }

    func notify(_ text: LocalizedStringResource, animate: Bool = true) {
        toastTask?.cancel()
        toastUsesMotion = animate
        toast = String(localized: text)
        toastTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(2.5))
                self?.toast = nil
            } catch {}
        }
    }

    /// Entries keep the resolved text so the activity search matches what is shown.
    func record(_ title: LocalizedStringResource, detail: String, symbol: String) {
        activity.insert(
            ActivityEntry(date: Date(), title: String(localized: title), detail: detail, symbol: symbol), at: 0)
        activity = Array(activity.prefix(100))
    }
}
