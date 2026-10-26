import AppKit
import PortsCore
import SwiftUI

@main
@MainActor
struct PortsApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    private var model: MonitorModel { delegate.model }

    var body: some Scene {
        Window(AppInfo.name, id: "monitor") {
            MonitorWindow(model: model)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .defaultSize(width: 504, height: 362)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Nach Updates suchen…") {
                    model.navigate(.settings)
                    model.revealWindow?()
                    model.checkForUpdates()
                }.disabled(model.onboardingSession != nil || model.hasPanelDialog)
            }
            CommandGroup(replacing: .newItem) {
                Button("Dienst starten…") {
                    PanelWindowCoordinator.shared.showLaunch(model: model)
                }.keyboardShortcut("n").disabled(
                    model.demoMode || model.onboardingSession != nil || model.hasPanelDialog)
            }
            CommandGroup(replacing: .appSettings) {
                Button("Einstellungen…") {
                    model.navigate(.settings)
                    model.revealWindow?()
                }.keyboardShortcut(",").disabled(model.onboardingSession != nil || model.hasPanelDialog)
            }
            CommandMenu("Arbeitsbereich") {
                Button("Aktualisieren") { Task { await model.refresh() } }.keyboardShortcut("r")
                Button(model.isMonitoring ? "Erkennung pausieren" : "Erkennung fortsetzen") {
                    model.isMonitoring.toggle()
                }
                Divider()
                Button("Übersicht") {
                    model.navigate(.overview)
                    model.revealWindow?()
                }.keyboardShortcut("1").disabled(model.onboardingSession != nil || model.hasPanelDialog)
                Button("AI-Agenten") {
                    model.navigate(.agents)
                    model.revealWindow?()
                }.keyboardShortcut("2").disabled(model.onboardingSession != nil || model.hasPanelDialog)
                Button("Dev-Server") {
                    model.navigate(.servers)
                    model.revealWindow?()
                }.keyboardShortcut("3").disabled(model.onboardingSession != nil || model.hasPanelDialog)
            }
            CommandGroup(replacing: .help) {
                Button("Einführung in Byte Ports…") { model.presentOnboarding() }
                    .disabled(model.hasPanelDialog)
            }
        }

        MenuBarExtra {
            CompactMonitorView(model: model)
        } label: {
            MenuBarLabel(model: model)
        }.menuBarExtraStyle(.window)
    }
}

/// Alive from launch, unlike the main window, so it owns the window opener.
struct MenuBarLabel: View {
    let model: MonitorModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Label {
            Text(model.counts.total, format: .number)
        } icon: {
            Image(systemName: "point.3.connected.trianglepath.dotted")
        }
        .onAppear { model.bindWindowOpener { openWindow(id: "monitor") } }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = MonitorModel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        model.startMonitoring()
        PanelWindowCoordinator.shared.configureNotch(model: model)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        model.showMainWindow()
        return false
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !model.isQuitting else { return .terminateLater }
        if model.launches.contains(where: { $0.state == .running }) {
            let alert = NSAlert()
            alert.messageText = "Es laufen noch gestartete Dienste."
            alert.informativeText =
                "Vor dem Beenden müssen die von Byte Ports gestarteten Dienste gestoppt werden. Extern gestartete Prozesse bleiben unberührt."
            alert.addButton(withTitle: "Abbrechen")
            alert.addButton(withTitle: "Dienste stoppen und beenden")
            guard alert.runModal() == .alertSecondButtonReturn else { return .terminateCancel }
        }
        model.isQuitting = true
        Task {
            do {
                try await model.tunnels.shutdown()
                let records = await model.launcher.records()
                for job in records where job.state == .running { try await model.launcher.stop(job.id) }
                sender.reply(toApplicationShouldTerminate: true)
            } catch {
                await model.tunnels.resumeAfterCancelledQuit()
                model.isQuitting = false
                model.report(error, as: .quit)
                model.revealWindow?()
                sender.reply(toApplicationShouldTerminate: false)
            }
        }
        return .terminateLater
    }
}
