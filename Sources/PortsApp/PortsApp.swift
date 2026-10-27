import AppKit
import PortsCore
import SwiftUI

@main
@MainActor
struct PortsApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    private var model: MonitorModel { delegate.model }
    private var opensInNotch: Bool { model.preferences.showNotch && model.onboardingSession == nil }

    var body: some Scene {
        Window(AppInfo.name, id: "monitor") {
            MonitorWindow(model: model)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .defaultSize(width: 504, height: 362)
        // With the notch enabled the panel opens there at launch, so the window must not appear first.
        .defaultLaunchBehavior(opensInNotch ? .suppressed : .presented)
        .restorationBehavior(opensInNotch ? .disabled : .automatic)
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
            CommandGroup(replacing: .appTermination) {
                Button("Quit \(AppInfo.name)") { QuitCoordinator.shared.requestQuit() }.keyboardShortcut("q")
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

/// Alive from launch, unlike the main window, so it owns the window opener. MenuBarExtra keeps only the label's image
/// and drops SwiftUI overlays and accessibility modifiers, so the image's own description is what VoiceOver reads.
struct MenuBarLabel: View {
    let model: MonitorModel
    @Environment(\.openWindow) private var openWindow

    /// A globe while a server is reachable from the internet, so the share stays visible with every panel closed.
    @MainActor private static let sharingGlyph =
        NSImage(
            systemSymbolName: "globe",
            accessibilityDescription: String(
                localized: "\(AppInfo.name) – public share active",
                comment: "VoiceOver description of the menu bar icon while a server is shared publicly"))
        ?? NSImage()

    var body: some View {
        Image(nsImage: model.isSharingPublicly ? Self.sharingGlyph : DS.portGlyph)
            .onAppear { model.bindWindowOpener { openWindow(id: "monitor") } }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = MonitorModel()

    /// Before any Apple event can ask the app to quit.
    func applicationWillFinishLaunching(_ notification: Notification) {
        QuitCoordinator.shared.model = model
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        model.startMonitoring()
        PanelWindowCoordinator.shared.configureNotch(model: model)
        StatusItemMenu.shared.install(model: model)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        model.showMainWindow()
        return false
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// Every terminate request, from a menu, an Apple event or a logout, goes through the quit flow.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        QuitCoordinator.shared.shouldTerminate(sender)
    }
}
