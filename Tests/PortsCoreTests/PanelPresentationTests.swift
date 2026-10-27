import Testing

@testable import PortsCore

struct PanelPresentationTests {
    @Test func enablingNotchMovesWindowPanelToNotch() {
        var state = PanelPresentation()
        #expect(state.home == .window)
        state.configureNotch(true)
        #expect(state.notchEnabled)
        #expect(state.home == .notch)
        #expect(state.active == .notch)
    }

    @Test func enablingNotchKeepsDialogInWindowAndLeavesOtherPanelsAlone() {
        var dialog = PanelPresentation()
        dialog.configureNotch(true, dialogOwner: .window)
        #expect(dialog.active == .window)
        var menu = PanelPresentation()
        menu.activate(.menu)
        menu.configureNotch(true)
        #expect(menu.active == .menu)
        var collapsed = PanelPresentation()
        collapsed.dismiss(.window)
        collapsed.configureNotch(true)
        #expect(collapsed.active == nil)
    }

    @Test func expandingNotchAndReopeningWindowTransferOwnership() {
        var state = PanelPresentation()
        state.configureNotch(true)
        let openedNotch = state.activate(.notch)
        #expect(openedNotch)
        #expect(state.active == .notch)
        let reopenedWindow = state.activate(.window)
        #expect(reopenedWindow)
        #expect(state.active == .window)
    }

    @Test func openingMenuReplacesExpandedNotch() {
        var state = PanelPresentation()
        state.configureNotch(true)
        state.activate(.notch)
        state.activate(.menu)
        #expect(state.active == .menu)
        #expect(state.notchEnabled)
    }

    @Test func disablingExpandedNotchRestoresWindow() {
        var state = PanelPresentation()
        state.configureNotch(true)
        state.activate(.notch)
        state.configureNotch(false)
        #expect(state.active == .window)
        #expect(!state.notchEnabled)
    }

    @Test func disablingInactiveNotchDoesNotOpenAnotherPanel() {
        var state = PanelPresentation()
        state.configureNotch(true)
        state.activate(.menu)
        state.configureNotch(false)
        #expect(state.active == .menu)
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
    }

    @Test func menuFormCanMoveToWindowBeforeLockingDialogOwner() {
        var state = PanelPresentation()
        state.configureNotch(true)
        state.activate(.menu)
        let openedWindow = state.activate(.window)
        let interruptedDialog = state.activate(.notch, dialogOwner: .window)
        #expect(openedWindow)
        #expect(!interruptedDialog)
        #expect(state.active == .window)
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
        let openedNotch = state.activate(.notch)
        #expect(!openedNotch)
        #expect(state.active == .window)
    }
}
