import AppKit
import Observation
import PortsCore
import SwiftUI

enum NavigationSection: String, CaseIterable, Identifiable {
    case overview, agents, servers, projects, actions, activity, settings
    var id: String { rawValue }
    var title: String {
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
    var errorMessage: String?
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
    @ObservationIgnored var revealWindow: (() -> Void)?

    init() {
        let arguments = ProcessInfo.processInfo.arguments
        let directory: URL
        if let index = arguments.firstIndex(of: "--state-directory"), arguments.indices.contains(index + 1) {
            directory = URL(fileURLWithPath: arguments[index + 1], isDirectory: true)
        } else {
            directory = URL.applicationSupportDirectory.appending(path: "Byte Ports", directoryHint: .isDirectory)
        }
        // Pre-release builds were called Byte Relay, the internal prototype DevScope.
        // Migrate from the newest of them that still has settings.
        let legacyURL =
            arguments.contains("--state-directory")
            ? nil
            : ["Byte Relay", "DevScope"]
                .map { URL.applicationSupportDirectory.appending(path: "\($0)/preferences.json") }
                .first { FileManager.default.fileExists(atPath: $0.path) }
        repository = PreferencesRepository(url: directory.appending(path: "preferences.json"), legacyURL: legacyURL)
        do { preferences = try repository.load() } catch {
            preferences = AppPreferences()
            persistenceAvailable = false
            errorMessage =
                "Die Einstellungen konnten nicht geladen werden. Die vorhandene Datei bleibt erhalten. \(error.localizedDescription)"
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
    var agents: [ServiceRecord] { services.filter { $0.kind == .agent } }
    var servers: [ServiceRecord] { services.filter { $0.kind == .server } }
    var selected: ServiceRecord? { services.first { $0.id == selectedID } }
    var visibleUniverse: [ServiceRecord] {
        services.filter { $0.kind != .listener || preferences.showOtherListeners }
    }

    var hasBlockingPanelDialog: Bool {
        showLaunchForm || pendingAction != nil || pendingJobStop != nil || pendingShare != nil
    }
    var hasPanelDialog: Bool { hasBlockingPanelDialog || errorMessage != nil }

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

    func dismissPanelDialog() {
        dialogUsesMotion = PanelMotion.isPointerEvent
        showLaunchForm = false
        pendingAction = nil
        pendingJobStop = nil
        pendingShare = nil
    }

    func confirmPublicSharing() {
        guard let target = pendingShare, !isQuitting, !demoMode else { return }
        do {
            guard persistenceAvailable else {
                throw MonitorError.scanFailed(
                    "Die Einstellungen sind nicht lesbar. Die Freigabe wurde nicht gestartet.")
            }
            var next = preferences
            next.hasAcknowledgedPublicSharing = true
            try repository.save(next)
            preferences = next
            dismissPanelDialog()
            share(target, from: presentationSurface)
        } catch { errorMessage = error.localizedDescription }
    }
    var filteredServices: [ServiceRecord] {
        filteredServices(in: section)
    }

    func filteredServices(in section: NavigationSection) -> [ServiceRecord] {
        visibleUniverse.filter { service in
            if section == .agents && service.kind != .agent { return false }
            if section == .servers && service.endpoints.isEmpty { return false }
            guard !search.isEmpty else { return true }
            let text =
                [
                    service.title, service.process.projectName, service.process.workingDirectory ?? "",
                    String(service.id.pid),
                ] + service.endpoints.map { String($0.port) }
            return text.contains { $0.localizedCaseInsensitiveContains(search) }
        }
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
            let next = try await scanner.scan(customRules: preferences.agentRules)
            guard generation == scanGeneration, !demoMode else { return }
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
        } catch { errorMessage = error.localizedDescription }
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
            try repository.save(next)
        }
        preferences = next
        if !persist && !persistenceAvailable { errorMessage = nil }
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
                } catch { errorMessage = error.localizedDescription }
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
            errorMessage =
                "Speichern ist deaktiviert, damit die nicht lesbare Einstellungsdatei erhalten bleibt. Details stehen in der README."
            return
        }
        do { try repository.save(preferences) } catch {
            errorMessage = "Einstellungen konnten nicht gespeichert werden: \(error.localizedDescription)"
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
                let verb = action == .pause ? "pausiert" : (action == .resume ? "fortgesetzt" : "Stop angefragt")
                record(
                    "\(service.title): \(verb)", detail: "PID \(service.id.pid)",
                    symbol: action == .pause ? "pause.circle" : "checkmark.circle")
                notify("\(service.title) · \(verb)")
                await refresh()
            } catch {
                errorMessage = error.localizedDescription
                await refresh()
            }
        }
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
            } catch { errorMessage = error.localizedDescription }
        }
    }

    func manageJob(_ job: LaunchRecord, restart: Bool) {
        guard !demoMode, busyJobs.insert(job.id).inserted else { return }
        Task {
            defer { busyJobs.remove(job.id) }
            do {
                if restart { logJobID = try await launcher.restart(job.id) } else { try await launcher.stop(job.id) }
                launches = await launcher.records()
                record(
                    "\(job.configuration.name) \(restart ? "neu gestartet" : "gestoppt")", detail: "Startaktion",
                    symbol: "arrow.clockwise")
                await refresh()
            } catch { errorMessage = error.localizedDescription }
        }
    }

    func showLogs(_ job: LaunchRecord) {
        logJobID = job.id
        showingLogs = true
        Task { logs = await launcher.output(for: job.id) }
    }

    func copy(_ value: String, message: String = "Kopiert", animateFeedback: Bool? = nil) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
        notify(message, animate: animateFeedback ?? PanelMotion.isPointerEvent)
    }

    func openEndpoint(_ endpoint: ListeningEndpoint) {
        guard !demoMode, let url = endpoint.url else { return }
        if !NSWorkspace.shared.open(url) { errorMessage = "Die Adresse konnte nicht geöffnet werden." }
    }

    func openDirectory(_ directory: String, terminal: Bool = false) {
        guard !demoMode else { return }
        let url = URL(fileURLWithPath: directory, isDirectory: true)
        if terminal {
            guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") else {
                errorMessage = "Terminal wurde nicht gefunden."
                return
            }
            NSWorkspace.shared.open([url], withApplicationAt: app, configuration: .init()) { [weak self] _, error in
                if let error { Task { @MainActor in self?.errorMessage = error.localizedDescription } }
            }
        } else if !NSWorkspace.shared.open(url) {
            errorMessage = "Der Projektordner konnte nicht geöffnet werden."
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

    func notify(_ text: String, animate: Bool = true) {
        toastTask?.cancel()
        toastUsesMotion = animate
        toast = text
        toastTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(2.5))
                self?.toast = nil
            } catch {}
        }
    }

    private func record(_ title: String, detail: String, symbol: String) {
        activity.insert(ActivityEntry(date: Date(), title: title, detail: detail, symbol: symbol), at: 0)
        activity = Array(activity.prefix(100))
    }
}
