import AppKit
import PortsCore
import SwiftUI

/// The panel lives in AppKit windows: MainPanelController and NotchController, toggled by StatusItemController. An
/// App needs a scene, so it keeps an empty Settings scene without its menu item; ⌘, opens settings in the panel instead,
/// so that scene never opens.
@main
@MainActor
struct PortsApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    /// Only commands that work without the panel. The panel's shortcuts belong to MonitorPanel and never go here as
    /// well: a key bound in both fires in a different place depending on which window is key.
    var body: some Scene {
        Settings { EmptyView() }
            .commands {
                CommandGroup(replacing: .appSettings) {}
                CommandGroup(replacing: .appTermination) {
                    Button("Quit \(AppInfo.name)") { QuitCoordinator.shared.requestQuit() }.keyboardShortcut("q")
                }
                // The window has a fixed size and hides instead of minimizing; there is no help book.
                CommandGroup(replacing: .windowSize) {}
                CommandGroup(replacing: .help) {}
            }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = MonitorModel()
    private var statusItem: StatusItemController?
    private var mainPanel: MainPanelController?

    /// Before any Apple event can ask the app to quit.
    func applicationWillFinishLaunching(_ notification: Notification) {
        QuitCoordinator.shared.model = model
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        model.startMonitoring()
        let statusItem = StatusItemController(model: model)
        let mainPanel = MainPanelController(model: model) { [weak statusItem] in statusItem?.screen }
        self.statusItem = statusItem
        self.mainPanel = mainPanel
        let coordinator = PanelWindowCoordinator.shared
        coordinator.install(model: model, mainPanel: mainPanel)
        coordinator.configureNotch(model: model)
        // While onboarding runs, home is the window.
        coordinator.showHome()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        PanelWindowCoordinator.shared.showHome()
        return false
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// Every terminate request, from a menu, an Apple event or a logout, goes through the quit flow.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        QuitCoordinator.shared.shouldTerminate(sender)
    }
}
