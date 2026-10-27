import Testing

@testable import PortsCore

struct PanelPresentationTests {
    @Test func onlyWindowAndNotchAreSurfaces() {
        #expect(MonitorSurface.allCases == [.window, .notch])
        #expect(PanelPresentation().active == nil)
    }

    @Test func homeIsTheNotchExactlyWhileItIsEnabled() {
        var state = PanelPresentation()
        #expect(state.home == .window)
        state.configureNotch(true)
        #expect(state.home == .notch)
        state.configureNotch(false)
        #expect(state.home == .window)
    }

    @Test(arguments: [false, true])
    func togglingHomeShowsItAndTogglingAgainHidesIt(notch: Bool) {
        var state = PanelPresentation()
        state.configureNotch(notch)
        let home: MonitorSurface = notch ? .notch : .window
        let shown = state.toggleHome()
        #expect(shown)
        #expect(state.active == home)
        let hidden = state.toggleHome()
        #expect(hidden)
        #expect(state.active == nil)
        #expect(state.notchEnabled == notch)
    }

    @Test func togglingHomeMovesThePanelFromTheOtherSurface() {
        var state = PanelPresentation()
        state.activate(.window)
        state.configureNotch(true, dialogOwner: .window)
        #expect(state.active == .window)
        let moved = state.toggleHome()
        #expect(moved)
        #expect(state.active == .notch)
    }

    @Test func showingHomeKeepsAnOpenHome() {
        var state = PanelPresentation()
        state.configureNotch(true)
        state.showHome()
        let shownAgain = state.showHome()
        #expect(shownAgain)
        #expect(state.active == .notch)
    }

    @Test func showingOneSurfaceReplacesTheOther() {
        var state = PanelPresentation()
        state.configureNotch(true)
        for surface in [MonitorSurface.notch, .window, .notch] {
            let shown = state.activate(surface)
            #expect(shown)
            #expect(state.active == surface)
        }
    }

    @Test func enablingNotchMovesWindowPanelToNotch() {
        var state = PanelPresentation()
        state.activate(.window)
        state.configureNotch(true)
        #expect(state.notchEnabled)
        #expect(state.active == .notch)
    }

    @Test func enablingNotchKeepsDialogInWindowAndHiddenPanelHidden() {
        var dialog = PanelPresentation()
        dialog.activate(.window)
        dialog.configureNotch(true, dialogOwner: .window)
        #expect(dialog.active == .window)
        var hidden = PanelPresentation()
        hidden.configureNotch(true)
        #expect(hidden.active == nil)
    }

    @Test func disablingExpandedNotchRestoresWindow() {
        var state = PanelPresentation()
        state.configureNotch(true)
        state.activate(.notch)
        state.configureNotch(false)
        #expect(state.active == .window)
        #expect(!state.notchEnabled)
    }

    @Test func disablingCollapsedNotchDoesNotOpenTheWindow() {
        var state = PanelPresentation()
        state.configureNotch(true)
        state.configureNotch(false)
        #expect(state.active == nil)
    }

    @Test(arguments: MonitorSurface.allCases)
    func unfinishedDialogKeepsItsOwner(owner: MonitorSurface) {
        var state = PanelPresentation()
        state.configureNotch(true)
        state.activate(owner)
        for destination in MonitorSurface.allCases {
            let accepted = state.activate(destination, dialogOwner: owner)
            #expect(accepted == (destination == owner))
            #expect(state.active == owner)
        }
        let toggled = state.toggleHome(dialogOwner: owner)
        #expect(toggled == (owner == .notch))
        #expect(state.active == owner)
        let shown = state.showHome(dialogOwner: owner)
        #expect(shown == (owner == .notch))
        #expect(state.active == owner)
    }

    @Test func delayedCloseOfPreviousWindowDoesNotCloseCurrentPanel() {
        var state = PanelPresentation()
        state.configureNotch(true)
        state.activate(.notch)
        state.dismiss(.window)
        #expect(state.active == .notch)
        state.dismiss(.notch)
        #expect(state.active == nil)
        #expect(state.notchEnabled)
    }

    @Test func disabledNotchCannotTakeOwnership() {
        var state = PanelPresentation()
        state.activate(.window)
        let openedNotch = state.activate(.notch)
        #expect(!openedNotch)
        #expect(state.active == .window)
    }
}
