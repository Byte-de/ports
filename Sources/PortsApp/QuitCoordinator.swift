import AppKit
import Observation
import PortsCore
import PortsFeatures
import SwiftUI

/// What the quit panel shows.
@MainActor @Observable
final class QuitPanelState {
    var flow: QuitFlow?
    /// Each job's state, polled while the panel is up.
    var states: [UUID: LaunchState] = [:]
    var hasActiveShares = false
}

/// Runs every quit: menus, Settings, Apple events and session ends all come here. Quitting is never blocked: a user
/// quit can always be cancelled or finished, and a session end always replies to AppKit.
@MainActor
final class QuitCoordinator {
    static let shared = QuitCoordinator()
    /// macOS gives a logout a few seconds; the watchdog replies even if a stop or share hangs.
    private static let sessionEndWatchdog: TimeInterval = 6
    private static let pollInterval = Duration.milliseconds(250)

    /// Set by AppDelegate before launch finishes; the delegate owns the model.
    weak var model: MonitorModel?
    /// The flow decided to terminate, so the applicationShouldTerminate that follows lets it through.
    private var approved = false
    /// When macOS announced a logout, restart or shutdown.
    private var sessionEndingSince: ContinuousClock.Instant?
    /// A session end returned .terminateLater and owes AppKit exactly one reply. Calling NSApp.terminate again
    /// meanwhile would end the app at once.
    private var replyPending = false
    private var watchdog: Timer?
    /// Bumped by every new flow and every cancel, so a superseded flow's results are dropped.
    private var generation = 0
    private var pollTask: Task<Void, Never>?
    private let state = QuitPanelState()
    private lazy var panel = QuitPanelController(rootView: QuitView(state: state, coordinator: self))
    private var powerOffObserver: (any NSObjectProtocol)?

    private init() {
        powerOffObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willPowerOffNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                PortsLog.lifecycle.notice("Power off announced")
                self?.sessionEndingSince = .now
            }
        }
    }

    /// The only entry for a user quit. While a flow runs it raises the panel instead of starting another.
    func requestQuit() {
        // A session end has no panel and finishes on its own.
        guard !replyPending else { return }
        if state.flow?.isActive == true {
            panel.present()
            return
        }
        guard let model else {
            // Nothing launched without a model. Deferred, because AppKit may be asking whether to terminate.
            Task { terminate() }
            return
        }
        guard !model.isQuitting else { return }
        model.beginQuit()
        start(sessionEnd: false)
    }

    /// AppKit's terminate request: the approved one, a session end, or an Apple event quit that runs the flow.
    func shouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if approved { return .terminateNow }
        // A second request while a reply is owed must neither cancel the logout nor answer twice.
        if replyPending { return .terminateLater }
        let reason = Self.currentQuitReason()
        let age = sessionEndingSince.map { $0.duration(to: .now) }
        guard SessionEnd.isSessionEnd(quitReason: reason, powerOffNoticeAge: age) else {
            requestQuit()
            return .terminateCancel
        }
        let notice = age.map { String(describing: $0) } ?? "none"
        PortsLog.lifecycle.notice(
            "Session ending: quit reason \(Self.describe(reason), privacy: .public), power-off notice \(notice, privacy: .public)"
        )
        replyPending = true
        let timer = Timer(timeInterval: Self.sessionEndWatchdog, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.watchdogFired() }
        }
        // The common modes include the one AppKit runs while it waits for the reply.
        RunLoop.main.add(timer, forMode: .common)
        watchdog = timer
        panel.orderOut(nil)
        model?.beginQuit()
        start(sessionEnd: true)
        return .terminateLater
    }

    func confirm() { send { $0.confirm() } }
    func cancel() { send { $0.cancel() } }
    func keepWaiting() { send { $0.keepWaiting() } }
    func forceQuit() { send { $0.forceQuit() } }
    func quitAnyway() { send { $0.quitAnyway() } }

    /// The names of `ids`, also for a job whose start finished after the quit read the list.
    func names(_ ids: Set<UUID>) -> [String] {
        let jobs = state.flow?.jobs ?? []
        let unknown = ids.subtracting(jobs.map(\.id))
        return jobs.filter { ids.contains($0.id) }.map(\.name)
            + (model?.launches.filter { unknown.contains($0.id) }.map(\.configuration.name) ?? [])
    }

    /// Reads the live jobs and shares, then asks or starts at once. A session end supersedes a running user flow.
    private func start(sessionEnd: Bool) {
        generation += 1
        let generation = generation
        stopPolling()
        state.flow = nil
        guard let model else {
            Task { terminate() }
            return
        }
        let launcher = model.launcher
        let tunnels = model.tunnels
        Task {
            let records = await launcher.records()
            let shares = await tunnels.records().count { $0.phase.isActive }
            guard generation == self.generation else { return }
            let active = records.filter(\.state.isActive)
            PortsLog.lifecycle.notice(
                "Quit requested: \(active.count, privacy: .public) jobs, \(shares, privacy: .public) shares")
            let flow = QuitFlow(
                jobs: active.map { QuitFlow.Job(id: $0.id, name: $0.configuration.name) }, isSessionEnd: sessionEnd)
            PortsLog.lifecycle.notice("Quit phase \(flow.phase.rawValue, privacy: .public)")
            state.flow = flow
            state.states = Dictionary(active.map { ($0.id, $0.state) }) { first, _ in first }
            state.hasActiveShares = shares > 0
            if flow.phase == .confirming {
                panel.present()
            } else {
                send { $0.begin() }
            }
        }
    }

    private func send(_ transition: (inout QuitFlow) -> QuitFlow.Effect) {
        guard var flow = state.flow else { return }
        let previous = flow.phase
        let effect = transition(&flow)
        state.flow = flow
        if flow.phase != previous {
            PortsLog.lifecycle.notice(
                "Quit phase \(previous.rawValue, privacy: .public) → \(flow.phase.rawValue, privacy: .public)")
            // A quit that began without a panel, such as one that read no jobs before a start slipped in, still
            // needs one once the user has to decide.
            if !flow.isSessionEnd, flow.phase == .unresponsive || flow.phase == .failed, !panel.isVisible {
                panel.present()
            }
        }
        perform(effect)
    }

    private func perform(_ effect: QuitFlow.Effect) {
        guard let model else {
            if effect == .terminate { terminate() }
            return
        }
        let launcher = model.launcher
        let generation = generation
        switch effect {
        case .none: return
        case .stopAll(let grace):
            let tunnels = model.tunnels
            startPolling()
            Task {
                // Shares end alongside the jobs; a share that fails to stop never holds up the quit.
                async let shares: Void = Self.endShares(tunnels)
                async let stopped = launcher.stopAll(grace: grace)
                let remaining = await stopped
                await shares
                guard generation == self.generation else { return }
                send { $0.stopFinished(remaining: remaining) }
            }
        case .wait(let grace):
            let ids = state.flow?.remaining ?? []
            Task {
                let remaining = await launcher.waitForAll(ids, grace: grace)
                guard generation == self.generation else { return }
                send { $0.stopFinished(remaining: remaining) }
            }
        case .forceStop(let ids):
            Task {
                let remaining = await launcher.forceStopAll(ids)
                guard generation == self.generation else { return }
                send { $0.forceFinished(remaining: remaining) }
            }
        case .terminate: terminate()
        case .resume: resume(model)
        }
    }

    private nonisolated static func endShares(_ tunnels: CloudflareTunnelManager) async {
        do { try await tunnels.shutdown() } catch {
            PortsLog.lifecycle.error(
                "Ending shares failed during quit: \(error.localizedDescription, privacy: .private)")
        }
    }

    private func terminate() {
        approved = true
        stopPolling()
        panel.orderOut(nil)
        if replyPending { replyToSessionEnd() } else { NSApp.terminate(nil) }
    }

    /// Both managers accept starts again; the app keeps running with whatever the stop left alive.
    private func resume(_ model: MonitorModel) {
        generation += 1
        let generation = generation
        stopPolling()
        panel.orderOut(nil)
        Task {
            await model.launcher.resumeAfterCancelledQuit()
            await model.tunnels.resumeAfterCancelledQuit()
            // A session end that began meanwhile keeps the app quitting.
            guard generation == self.generation else { return }
            model.isQuitting = false
            await model.reloadLaunches()
        }
    }

    private func replyToSessionEnd() {
        guard replyPending else { return }
        replyPending = false
        watchdog?.invalidate()
        watchdog = nil
        approved = true
        NSApp.reply(toApplicationShouldTerminate: true)
    }

    private func watchdogFired() {
        guard replyPending else { return }
        PortsLog.lifecycle.error("Session end watchdog fired before the stop finished")
        generation += 1
        stopPolling()
        replyToSessionEnd()
    }

    /// Feeds the panel's per-service spinners and checks. Session ends have no panel and are not polled.
    private func startPolling() {
        guard pollTask == nil, let flow = state.flow, !flow.isSessionEnd, !flow.jobs.isEmpty,
            let launcher = model?.launcher
        else { return }
        let ids = flow.jobs.map(\.id)
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                var states: [UUID: LaunchState] = [:]
                for id in ids { states[id] = await launcher.status(for: id) }
                guard let self, !Task.isCancelled else { return }
                if self.state.states != states { self.state.states = states }
                do { try await Task.sleep(for: Self.pollInterval) } catch { return }
            }
        }
    }

    private func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    /// The reason macOS attaches to the quit Apple event of a logout, restart or shutdown; nil for other quits.
    private static func currentQuitReason() -> FourCharCode? {
        guard let event = NSAppleEventManager.shared().currentAppleEvent,
            let descriptor = event.attributeDescriptor(forKeyword: kAEQuitReason)
                ?? event.paramDescriptor(forKeyword: kAEQuitReason)
        else { return nil }
        return descriptor.enumCodeValue != 0 ? descriptor.enumCodeValue : descriptor.typeCodeValue
    }

    /// A four-character code such as 'rlgo', for the log.
    private static func describe(_ code: FourCharCode?) -> String {
        guard let code else { return "none" }
        let bytes = [24, 16, 8, 0].map { UInt8(truncatingIfNeeded: code >> $0) }
        return String(bytes: bytes, encoding: .macOSRoman) ?? String(code)
    }
}

/// A floating panel that stays usable while the app is inactive: activation may be refused, so it orders front
/// regardless and takes the first click without needing key status.
@MainActor
private final class QuitPanelController: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    init(rootView: QuitView) {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        title = String(
            localized: "Quit \(AppInfo.name)",
            comment: "Title of the quit panel, read by VoiceOver; the argument is the app's name")
        appearance = NSAppearance(named: .darkAqua)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isMovableByWindowBackground = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        contentView = FirstMouseHostingView(rootView: rootView)
    }

    /// Centred on the screen under the pointer when it appears; a raise leaves a moved panel where it is.
    func present() {
        if !isVisible, let content = contentView {
            let pointer = NSEvent.mouseLocation
            if let screen = NSScreen.screens.first(where: { $0.frame.contains(pointer) }) ?? NSScreen.main {
                content.layoutSubtreeIfNeeded()
                let size = content.fittingSize
                let area = screen.visibleFrame
                setFrame(
                    NSRect(
                        x: area.midX - size.width / 2, y: area.midY - size.height / 2, width: size.width,
                        height: size.height), display: false)
            }
        }
        NSApp.activate()
        makeKeyAndOrderFront(nil)
        orderFrontRegardless()
    }
}

/// Buttons react to the first click even while the panel is not key.
private final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

private struct QuitView: View {
    let state: QuitPanelState
    let coordinator: QuitCoordinator
    /// More services are summarised in one line.
    private static let listedJobs = 4

    var body: some View {
        if let flow = state.flow {
            VStack(alignment: .leading, spacing: 16) {
                Text(verbatim: title(flow)).font(.system(size: 17, weight: .medium))
                    .fixedSize(horizontal: false, vertical: true).accessibilityAddTraits(.isHeader)
                if let message = message(flow) {
                    Text(verbatim: message).font(.system(size: 12)).foregroundStyle(DS.muted).lineSpacing(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !flow.jobs.isEmpty { jobs(flow) }
                actions(flow)
            }
            .padding(24).frame(width: 420, alignment: .leading).background(PanelGlass())
            .foregroundStyle(DS.text).preferredColorScheme(.dark).accessibilityElement(children: .contain)
        }
    }

    private func title(_ flow: QuitFlow) -> String {
        switch flow.phase {
        case .confirming:
            return String(
                localized: "Stop launched services?", comment: "Quit panel title before stopping launched services")
        case .stopping, .finished, .cancelled:
            return String(localized: "Stopping services…", comment: "Quit panel title while launched services stop")
        case .unresponsive:
            return String(
                localized: "Some services aren't responding",
                comment: "Quit panel title when launched services are still running after the stop request")
        case .forcing:
            return String(localized: "Force quitting services…", comment: "Quit panel title while Force Quit runs")
        case .failed:
            // The count picks the verb form and is not shown.
            let names = coordinator.names(flow.remaining)
            return String(
                localized: "\(names.count) services couldn't be stopped: \(names.formatted(.list(type: .and)))",
                comment: "Quit panel title when services survived Force Quit; the arguments count and list their names")
        }
    }

    private func message(_ flow: QuitFlow) -> String? {
        switch flow.phase {
        case .confirming:
            let stops = String(
                localized: "Before quitting, the app stops these services. Processes started elsewhere keep running.",
                comment: "Quit panel explanation before stopping launched services")
            guard state.hasActiveShares else { return stops }
            let shares = String(
                localized: "Active shares end as well.",
                comment: "Quit panel note when public shares are active; follows the stop explanation")
            return stops + " " + shares
        case .unresponsive:
            // The count picks the verb form and is not shown.
            let names = coordinator.names(flow.remaining)
            return String(
                localized:
                    "\(names.count) services are still running 15 seconds after the stop request: \(names.formatted(.list(type: .and))). Force Quit ends the processes the app started, without cleanup; unsaved data may be lost.",
                comment:
                    "Quit panel explanation for services that ignore the stop request; the arguments count and list their names"
            )
        case .failed:
            return String(
                localized:
                    "\(flow.remaining.count) processes didn't respond to Force Quit either. Check them in Activity Monitor. If you quit anyway, they keep running without the app.",
                comment:
                    "Quit panel explanation when Force Quit did not end some services; the count picks singular or plural and is not shown"
            )
        case .stopping, .forcing, .finished, .cancelled:
            return nil
        }
    }

    private func jobs(_ flow: QuitFlow) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(flow.jobs.prefix(Self.listedJobs)) { job in
                HStack(spacing: 8) {
                    indicator(job, in: flow).frame(width: 14, height: 14)
                    Text(verbatim: job.name).font(.system(size: 12)).lineLimit(1).truncationMode(.middle)
                }.accessibilityElement(children: .combine)
            }
            if flow.jobs.count > Self.listedJobs {
                Text(
                    verbatim: String(
                        localized: "+ \(flow.jobs.count - Self.listedJobs) more",
                        comment:
                            "Last line of the quit panel's service list; the argument counts the services not shown")
                ).font(.system(size: 12)).foregroundStyle(DS.muted).padding(.leading, 22)
            }
        }
    }

    /// While stopping, a job's polled state decides; once a result is in, the flow's remaining jobs do.
    @ViewBuilder private func indicator(_ job: QuitFlow.Job, in flow: QuitFlow) -> some View {
        let settled = flow.phase == .unresponsive || flow.phase == .failed
        if flow.phase == .confirming {
            Circle().fill(DS.accent).frame(width: 5, height: 5).accessibilityHidden(true)
        } else if settled ? !flow.remaining.contains(job.id) : state.states[job.id]?.isActive == false {
            Image(systemName: "checkmark").font(.system(size: 11, weight: .semibold)).foregroundStyle(DS.accent)
                .accessibilityLabel(Text(verbatim: String(localized: "Stopped", comment: "A launched service ended")))
        } else if settled {
            Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 11)).foregroundStyle(DS.orange)
                .accessibilityLabel(
                    Text(verbatim: String(localized: "Not responding", comment: "A launched service ignores a stop")))
        } else {
            ProgressView().controlSize(.mini)
                .accessibilityLabel(
                    Text(verbatim: String(localized: "Stopping…", comment: "A launched service is being stopped")))
        }
    }

    @ViewBuilder private func actions(_ flow: QuitFlow) -> some View {
        HStack(spacing: 8) {
            switch flow.phase {
            case .confirming:
                Spacer()
                Button(String(localized: "Cancel", comment: "Closes the quit panel; the app keeps running")) {
                    coordinator.cancel()
                }.buttonStyle(QuietButton()).keyboardShortcut(.cancelAction)
                Button(String(localized: "Stop and Quit", comment: "Stops launched services, then quits the app")) {
                    coordinator.confirm()
                }.buttonStyle(AccentButton()).keyboardShortcut(.defaultAction)
            case .stopping, .forcing:
                Spacer()
                cancelQuit
            case .unresponsive:
                // Losing unsaved data takes a deliberate click: Return keeps waiting.
                Button(
                    String(localized: "Force Quit", comment: "Kills launched services that ignore the stop request"),
                    role: .destructive
                ) { coordinator.forceQuit() }.buttonStyle(QuietButton(tint: DS.red))
                Spacer()
                cancelQuit
                Button(
                    String(localized: "Keep Waiting", comment: "Waits another 15 seconds without signalling again")
                ) { coordinator.keepWaiting() }.buttonStyle(AccentButton()).keyboardShortcut(.defaultAction)
            case .failed:
                Spacer()
                cancelQuit
                Button(String(localized: "Quit Anyway", comment: "Quits and leaves the remaining service running")) {
                    coordinator.quitAnyway()
                }.buttonStyle(AccentButton()).keyboardShortcut(.defaultAction)
            case .finished, .cancelled:
                EmptyView()
            }
        }
    }

    private var cancelQuit: some View {
        Button(String(localized: "Cancel Quit", comment: "Stops quitting; the app keeps running")) {
            coordinator.cancel()
        }.buttonStyle(QuietButton()).keyboardShortcut(.cancelAction)
    }
}
