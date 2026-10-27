import AppKit
import Observation
import PortsCore
import PortsFeatures
import SwiftUI

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
/// A force stop awaiting confirmation. `restartAfter` when it ends a restart that timed out, which then starts.
struct PendingForceStop {
    let job: LaunchRecord
    let restartAfter: Bool
}
/// The launch form on screen. Every presentation has its own id, so the form starts from its request's fields.
struct LaunchFormRequest: Identifiable {
    enum Mode {
        case create(LaunchDraft)
        case edit(LaunchConfiguration)
    }
    let id = UUID()
    let mode: Mode
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
    /// Shared by every surface: one panel is on screen at a time.
    var navigation = PanelNavigation()
    var navigationUsesMotion = false
    var presentationSurface: MonitorSurface = .window
    var snapshot = ScanSnapshot(services: [], processCount: 0)
    var hasScanned = false
    var isLaunching = false
    /// Rows whose start or restart waits for the shell environment.
    var loadingShellEnvironment: Set<UUID> = []
    /// The form's start while it waits for the shell environment. Dismissing the form clears it to cancel the start.
    var pendingFormLaunch: UUID?
    var demoMode = false
    var panelError: PanelError?
    /// Shown inline instead of an alert, because scans repeat every few seconds.
    var detectionIssue: String?
    var toast: String?
    var toastUsesMotion = false
    var dialogUsesMotion = false
    var pendingAction: PendingAction?
    var pendingJobStop: LaunchRecord?
    var pendingForceStop: PendingForceStop?
    var pendingShare: TunnelTarget?
    var updateStatus: UpdateStatus = .idle
    var launchForm: LaunchFormRequest?
    /// A saved action awaiting confirmation of its deletion.
    var pendingActionDeletion: LaunchConfiguration?
    var onboardingSession: UUID?
    var launches: [LaunchRecord] = []
    var activity: [ActivityEntry] = []
    var preferences: AppPreferences
    var histories: [ProcessIdentity: [Double]] = [:]
    var busyIDs: Set<ProcessIdentity> = []
    /// Slots with a stop, restart or force stop in progress.
    var busyJobs: Set<UUID> = []
    var restartingJobs: Set<UUID> = []
    /// Slots whose restart timed out: confirming their force stop starts them again.
    var restartAfterForce: Set<UUID> = []
    var tunnelRecords: [TunnelRecord] = []
    var sharingBusy: Set<TunnelKey> = []
    /// Ports that answered something other than HTTP when sharing started, until their process exits.
    var nonHTTPTargets: Set<TunnelKey> = []
    var isQuitting = false
    var isSwitchingDemo = false
    @ObservationIgnored let tunnels = CloudflareTunnelManager(
        client: Bundle.main.bundleURL.appending(path: "Contents/Helpers/cloudflared"),
        runner: Bundle.main.bundleURL.appending(path: "Contents/Helpers/ports-tunnel-runner"))
    @ObservationIgnored var tunnelObserver: Task<Void, Never>?
    @ObservationIgnored var launchObserver: Task<Void, Never>?
    /// Shares whose link may still be copied without a second click.
    @ObservationIgnored var pendingShareCopies: [TunnelKey: ShareLinkHandoff] = [:]
    @ObservationIgnored private let scanner = ProcessScanner()
    @ObservationIgnored private let controller = ProcessController()
    @ObservationIgnored let launcher = LaunchManager()
    @ObservationIgnored private let repository: PreferencesRepository
    @ObservationIgnored private var persistenceAvailable = true
    @ObservationIgnored private var scanGeneration = 0
    @ObservationIgnored private lazy var refresher = RefreshCoalescer { [weak self] in await self?.scanOnce() }
    @ObservationIgnored private var loopTask: Task<Void, Never>?
    /// Observed, so the output page reads new output only while its surface is on screen.
    private var visibleSurfaces: Set<MonitorSurface> = []
    @ObservationIgnored private var systemIdle = false
    @ObservationIgnored private var nextScanWait: Task<Void, Never>?
    @ObservationIgnored private var scanRequested = false
    @ObservationIgnored private var systemObservers: [any NSObjectProtocol] = []
    @ObservationIgnored private var toastTask: Task<Void, Never>?

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
        }
        if arguments.contains("--onboarding") || (!preferences.hasCompletedOnboarding && !demoMode) {
            onboardingSession = UUID()
        }
    }

    var services: [ServiceRecord] { snapshot.services }
    var visibleUniverse: [ServiceRecord] {
        ServiceListing.visible(services, filter: .all, search: "", showsListeners: preferences.showOtherListeners)
    }
    var counts: ServiceCounts { ServiceCounts(visibleUniverse) }

    /// Automatic detection. A pause is a saved setting, so it survives a relaunch.
    var isMonitoring: Bool { preferences.detectsAutomatically }

    /// The one way to pause or resume: Settings, the paused badge and the menu command. Resuming scans at once.
    func setMonitoring(_ enabled: Bool) {
        guard enabled != preferences.detectsAutomatically else { return }
        preferences.detectsAutomatically = enabled
        PortsLog.scan.notice("Automatic detection \(enabled ? "resumed" : "paused", privacy: .public)")
        savePreferences()
        if enabled && !demoMode { wakeScanLoop() }
    }

    /// Shows the panel at home: the expanded notch while it is enabled, otherwise the window.
    func showMainWindow() { PanelWindowCoordinator.shared.showHome() }

    var hasBlockingPanelDialog: Bool {
        launchForm != nil || pendingActionDeletion != nil || pendingAction != nil || pendingJobStop != nil
            || pendingForceStop != nil || pendingShare != nil
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
        launchForm = nil
        pendingFormLaunch = nil
        pendingActionDeletion = nil
        pendingAction = nil
        pendingJobStop = nil
        pendingForceStop = nil
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

    /// A tab's services, with the services of one project next to each other.
    func visibleServices(_ filter: ServiceFilter, search: String) -> [ServiceRecord] {
        ServiceListing.groupedByProject(
            ServiceListing.visible(
                services, filter: filter, search: search, showsListeners: preferences.showOtherListeners))
    }

    /// nil once the process has exited; its details then stay open with an empty state.
    func service(for id: ProcessIdentity) -> ServiceRecord? { services.first { $0.id == id } }

    /// The job whose output is the page on top.
    var outputJobID: UUID? {
        if case .output(let id) = navigation.top { return id }
        return nil
    }

    /// Shows a tab's root; selecting the open tab again pops to it.
    func select(_ tab: PanelTab) {
        navigationUsesMotion = PanelMotion.animatesInteraction
        navigation.select(tab)
    }

    func push(_ destination: PanelDestination) {
        navigationUsesMotion = PanelMotion.animatesInteraction
        navigation.push(destination)
    }

    func goBack() {
        navigationUsesMotion = PanelMotion.animatesInteraction
        navigation.pop()
    }

    func showDetails(_ service: ServiceRecord, from surface: MonitorSurface) {
        presentationSurface = surface
        push(.details(service.id))
    }

    /// A server whose primary port answers HTTP as far as the app knows: no database, no port whose share check got
    /// something else back.
    func speaksHTTP(_ service: ServiceRecord) -> Bool {
        guard service.kind == .server, let endpoint = service.primaryEndpoint else { return false }
        return !answersNoHTTP(service, port: endpoint.port)
    }

    /// Only an app comes forward: no terminal can attach to a running command-line session.
    func canActivate(_ service: ServiceRecord) -> Bool { service.isDesktopApplication }

    /// What a click on the row does. The demo's processes don't exist, so its rows show details.
    func primaryAction(for service: ServiceRecord) -> ServicePrimaryAction {
        guard !demoMode else { return .showDetails }
        return ServicePrimaryAction.resolve(
            for: service, speaksHTTP: speaksHTTP(service), canActivate: canActivate(service))
    }

    func performPrimaryAction(_ service: ServiceRecord, from surface: MonitorSurface) {
        // An error or the details page appears where the row was clicked.
        presentationSurface = surface
        switch primaryAction(for: service) {
        case .openURL(let url):
            if !NSWorkspace.shared.open(url) { report("The address couldn't be opened.", as: .open) }
        case .activate: activate(service)
        case .showDetails: showDetails(service, from: surface)
        }
    }

    func startMonitoring() {
        guard loopTask == nil else { return }
        observeTunnels()
        startLaunchObserver()
        observeSystemActivity()
        loopTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if self.isMonitoring && !self.demoMode { await self.refresh() }
                await self.waitForNextScan()
            }
        }
    }

    func isShowing(_ surface: MonitorSurface) -> Bool { visibleSurfaces.contains(surface) }

    var scanActivity: ScanActivity {
        if systemIdle { return .idle }
        return visibleSurfaces.isEmpty ? .background : .visible
    }

    private var scanInterval: Duration {
        ScanCadence.interval(preferred: .seconds(preferences.refreshInterval), activity: scanActivity)
    }

    /// The window coordinator and the notch report whenever a surface may have appeared or disappeared.
    func setSurface(_ surface: MonitorSurface, visible: Bool) {
        let previous = scanActivity
        let wasVisible = !visibleSurfaces.isEmpty
        var next = visibleSurfaces
        if visible { next.insert(surface) } else { next.remove(surface) }
        // Assigned only on change: the surfaces report often, and an assignment redraws the output page.
        if next != visibleSurfaces { visibleSurfaces = next }
        if ScanCadence.shouldScanNow(
            wasVisible: wasVisible, isVisible: !visibleSurfaces.isEmpty, hasScanned: hasScanned,
            snapshotAge: .seconds(Date().timeIntervalSince(snapshot.scannedAt)),
            interval: .seconds(preferences.refreshInterval))
        {
            wakeScanLoop()
        }
        activityChanged(from: previous)
    }

    private func setSystemIdle(_ idle: Bool) {
        guard idle != systemIdle else { return }
        let previous = scanActivity
        systemIdle = idle
        activityChanged(from: previous)
        if !idle { wakeScanLoop() }
    }

    /// Ends the wait between scans, so the loop scans at once.
    func wakeScanLoop() {
        scanRequested = true
        nextScanWait?.cancel()
    }

    /// A waiting loop recomputes its deadline, so an appearing surface gets the preferred rate without first sitting
    /// out a background interval.
    private func activityChanged(from previous: ScanActivity) {
        let activity = scanActivity
        guard activity != previous else { return }
        let interval = scanInterval
        PortsLog.scan.debug(
            "Scan activity \(activity.rawValue, privacy: .public), every \(interval, privacy: .public)")
        nextScanWait?.cancel()
    }

    /// Sleeps until the next scan is due at the current cadence, counted from the end of the last scan.
    private func waitForNextScan() async {
        let start = ContinuousClock.now
        // A wake that arrived during the scan that just ran is covered by it.
        scanRequested = false
        while !scanRequested && !Task.isCancelled {
            let deadline = start + scanInterval
            guard deadline > .now else { return }
            let wait = Task { _ = try? await Task.sleep(until: deadline, clock: .continuous) }
            nextScanWait = wait
            await withTaskCancellationHandler {
                await wait.value
            } onCancel: {
                wait.cancel()
            }
        }
    }

    /// Display sleep, system sleep and a switch to another user stretch the cadence to the idle floor.
    private func observeSystemActivity() {
        let center = NSWorkspace.shared.notificationCenter
        let changes: [(Notification.Name, idle: Bool)] = [
            (NSWorkspace.screensDidSleepNotification, true), (NSWorkspace.willSleepNotification, true),
            (NSWorkspace.sessionDidResignActiveNotification, true), (NSWorkspace.screensDidWakeNotification, false),
            (NSWorkspace.didWakeNotification, false), (NSWorkspace.sessionDidBecomeActiveNotification, false),
        ]
        systemObservers = changes.map { name, idle in
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.setSystemIdle(idle) }
            }
        }
    }

    /// Joins a running scan instead of being dropped, and returns after a scan that started after the call.
    func refresh() async {
        guard !demoMode else { return }
        await refresher.request()
    }

    private func scanOnce() async {
        guard !demoMode else { return }
        let generation = scanGeneration
        do {
            #if DEBUG
                // Manual check of the inline failure line: scans fail while this file exists.
                let failureSwitch = FileManager.default.temporaryDirectory.appending(path: "ports-fail-scans")
                if FileManager.default.fileExists(atPath: failureSwitch.path) {
                    throw MonitorError.scanFailed(
                        String(localized: "The process list is not available.", comment: "Scan error"))
                }
            #endif
            let next = try await scanner.scan(customRules: preferences.agentRules)
            guard generation == scanGeneration, !demoMode else { return }
            detectionIssue = nil
            let previousIDs = Set(services.map(\.id))
            let nextIDs = Set(next.services.map(\.id))
            if hasScanned {
                for service in next.services where !previousIDs.contains(service.id) && service.kind != .listener {
                    record("\(service.title) detected", detail: service.process.projectName, symbol: "plus.circle")
                }
                // A failed listener query cannot prove that a service exited.
                if next.warning == nil {
                    for service in services where !nextIDs.contains(service.id) && service.kind != .listener {
                        record(
                            "\(service.title) is no longer active", detail: service.process.projectName,
                            symbol: "minus.circle")
                    }
                }
            }
            snapshot = next
            hasScanned = true
            // A scan without listeners can't prove an exit. Assigned only when something is pruned, so rows don't
            // redraw after every scan.
            let presentNonHTTP = nonHTTPTargets.filter { nextIDs.contains($0.process) }
            if next.warning == nil, presentNonHTTP.count != nonHTTPTargets.count { nonHTTPTargets = presentNonHTTP }
            histories = histories.filter { nextIDs.contains($0.key) }
            for service in services {
                if let value = service.cpuPercent {
                    histories[service.id, default: []].append(value)
                    histories[service.id] = Array(histories[service.id, default: []].suffix(40))
                }
            }
        } catch {
            PortsLog.scan.error("Scan failed: \(error.localizedDescription, privacy: .private)")
            if generation == scanGeneration && !demoMode { detectionIssue = error.localizedDescription }
        }
        if !launches.isEmpty { await reloadLaunches() }
    }

    func presentOnboarding() {
        guard !hasPanelDialog else { return }
        presentationSurface = .window
        if onboardingSession == nil { onboardingSession = UUID() }
        // The introduction always runs in the window.
        PanelWindowCoordinator.shared.showWindow()
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
        navigation.select(.servers)
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
                    pendingShareCopies.removeAll()
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
        histories = [:]
        navigation.select(.servers)
        detectionIssue = nil
        if demoMode {
            snapshot = DemoData.snapshot
            hasScanned = true
        } else {
            snapshot = ScanSnapshot(services: [], processCount: 0)
            hasScanned = false
            Task { await refresh() }
        }
    }

    func savePreferences() {
        guard persistenceAvailable else { return reportSavingDisabled() }
        do { try writePreferences(preferences) } catch { report(error, as: .preferencesSave) }
    }

    /// Saves first and applies the change only once it is on disk, so the panel never shows a change a relaunch would
    /// lose. A failure is reported.
    @discardableResult func commitPreferences(_ change: (inout AppPreferences) -> Void) -> Bool {
        guard persistenceAvailable else {
            reportSavingDisabled()
            return false
        }
        var next = preferences
        change(&next)
        do { try writePreferences(next) } catch {
            report(error, as: .preferencesSave)
            return false
        }
        preferences = next
        return true
    }

    /// Like `commitPreferences(_:)` for what the app remembers on its own, such as the last folder: a failure is only
    /// logged, because nothing the user did was lost.
    @discardableResult func persistQuietly(_ change: (inout AppPreferences) -> Void) -> Bool {
        guard persistenceAvailable else {
            PortsLog.persistence.info("Skipped a background save: saving is turned off")
            return false
        }
        var next = preferences
        change(&next)
        // writePreferences logs the failure.
        guard (try? writePreferences(next)) != nil else { return false }
        preferences = next
        return true
    }

    private func reportSavingDisabled() {
        report(
            "Saving is turned off so the unreadable settings file is kept. The README has details.",
            as: .preferencesSave)
    }

    /// Logs a failed save; callers decide whether and how to present it.
    private func writePreferences(_ next: AppPreferences) throws {
        do { try repository.save(next) } catch {
            PortsLog.persistence.error("Saving preferences failed: \(error.localizedDescription, privacy: .private)")
            throw error
        }
    }

    /// Whether the app may pause or stop the process at all. Rows, menus and details hide what it rules out.
    func isControllable(_ service: ServiceRecord) -> Bool {
        !demoMode && controller.isControllable(service.process)
    }

    /// Controllable and not waiting for an earlier pause, resume or stop.
    func canControl(_ service: ServiceRecord) -> Bool {
        isControllable(service) && !busyIDs.contains(service.id)
    }

    func request(_ action: ProcessAction, service: ServiceRecord, from surface: MonitorSurface = .window) {
        guard canControl(service), !hasPanelDialog else { return }
        presentationSurface = surface
        if action == .terminate {
            dialogUsesMotion = PanelMotion.isPointerEvent
            pendingAction = PendingAction(service: service, action: action)
        } else {
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
                    entry = "\(service.title): paused"
                    message = "\(service.title) · paused"
                case .resume:
                    entry = "\(service.title): resumed"
                    message = "\(service.title) · resumed"
                case .terminate:
                    entry = "\(service.title): stop requested"
                    message = "\(service.title) · stop requested"
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
        if let directory = service.projectDirectory {
            openDirectory(directory, terminal: true)
        }
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
