import AppKit
import PortsCore
import SwiftUI

@main
@MainActor
struct PortsApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = MonitorModel()

    var body: some Scene {
        Window("Byte Ports", id: "monitor") {
            MonitorWindow(model: model).onAppear { delegate.model = model }
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
            Label("\(model.agents.count + model.servers.count)", systemImage: "point.3.connected.trianglepath.dotted")
        }.menuBarExtraStyle(.window)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var model: MonitorModel?
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model else { return .terminateNow }
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
                model.errorMessage = error.localizedDescription
                model.revealWindow?()
                sender.reply(toApplicationShouldTerminate: false)
            }
        }
        return .terminateLater
    }
}
