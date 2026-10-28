import CoreGraphics
import PortsFeatures
import Testing

struct NotchLayoutTests {
    /// A 2560 × 1440 primary display with a 30 pt menu bar, as measured on macOS 26.
    private let external = NotchScreen(
        id: 1, frame: CGRect(x: 0, y: 0, width: 2560, height: 1440),
        visibleFrame: CGRect(x: 0, y: 0, width: 2560, height: 1410))
    /// A 14-inch built-in display to the right of it, with a 38 pt notch and 662 pt unobscured on either side.
    private let builtIn = NotchScreen(
        id: 2, frame: CGRect(x: 2560, y: 0, width: 1512, height: 982),
        visibleFrame: CGRect(x: 2560, y: 0, width: 1512, height: 944), safeAreaTop: 38,
        auxiliaryTopLeft: CGRect(x: 2560, y: 944, width: 662, height: 38),
        auxiliaryTopRight: CGRect(x: 3410, y: 944, width: 662, height: 38))
    /// A vertical display left of and below the primary one, with its own menu bar.
    private let vertical = NotchScreen(
        id: 3, frame: CGRect(x: -1440, y: -1120, width: 1440, height: 2560),
        visibleFrame: CGRect(x: -1440, y: -1120, width: 1440, height: 2530))

    @Test func prefersNotchedBuiltInOverPrimaryExternal() {
        #expect(NotchLayout.preferredScreen([external, builtIn]) == builtIn)
        #expect(NotchLayout.preferredScreen([builtIn, vertical]) == builtIn)
    }

    @Test func fallsBackToFirstScreenWithoutNotch() {
        #expect(NotchLayout.preferredScreen([external, vertical]) == external)
        #expect(NotchLayout.preferredScreen([vertical, external]) == vertical)
        #expect(NotchLayout.preferredScreen([]) == nil)
        // Both unobscured areas are needed; an inset alone is not a notch.
        var insetOnly = builtIn
        insetOnly.auxiliaryTopRight = nil
        #expect(NotchLayout.preferredScreen([external, insetOnly]) == external)
    }

    @Test func menuBarHeightUsesVisibleFrame() {
        #expect(NotchLayout.menuBarHeight(external) == 30)
        #expect(NotchLayout.menuBarHeight(vertical) == 30)
        #expect(NotchLayout.menuBarHeight(builtIn) == 38)
    }

    @Test func compactFrameHugsNotch() throws {
        let notch = try #require(NotchLayout.notch(builtIn))
        #expect(notch == CGRect(x: 3222, y: 944, width: 188, height: 38))
        #expect(NotchLayout.compactFrame(builtIn, hovering: false) == notch)
        let revealed = try #require(NotchLayout.compactFrame(builtIn, hovering: true))
        #expect(revealed.width == notch.width + 2 * NotchLayout.earWidth)
        #expect(revealed.height == 38)
        #expect(revealed.maxY == builtIn.frame.maxY)
        #expect(revealed.midX == notch.midX)
    }

    @Test func compactFrameNeverWiderThanNotchWhenNotHovered() throws {
        let notch = try #require(NotchLayout.notch(builtIn))
        let resting = try #require(NotchLayout.compactFrame(builtIn, hovering: false, sharing: false))
        #expect(resting.width <= notch.width)
        #expect(resting.height <= notch.height)
        // A crowded menu bar keeps its items next to the notch: nothing resting there is wider than the notch.
        #expect(resting.minX >= notch.minX && resting.maxX <= notch.maxX)
    }

    @Test func shareShowsEarsOnlyBesideANotch() throws {
        let notch = try #require(NotchLayout.notch(builtIn))
        let sharing = try #require(NotchLayout.compactFrame(builtIn, hovering: false, sharing: true))
        #expect(sharing.width == notch.width + 2 * NotchLayout.earWidth)
        let plain = try #require(NotchLayout.compactFrame(external, hovering: false, sharing: true))
        #expect(plain.height == NotchLayout.hotZoneHeight)
        #expect(NotchLayout.revealsCounts(builtIn, hovering: false, sharing: true))
        #expect(!NotchLayout.revealsCounts(external, hovering: false, sharing: true))
        #expect(!NotchLayout.revealsCounts(builtIn, hovering: false, sharing: false))
        #expect(NotchLayout.revealsCounts(external, hovering: true))
    }

    @Test func plainScreenRestsAsAHotZoneAtTheTop() throws {
        let zone = try #require(NotchLayout.compactFrame(external, hovering: false))
        #expect(zone == CGRect(x: 1206, y: 1436, width: 148, height: 4))
        let pill = try #require(NotchLayout.compactFrame(external, hovering: true))
        #expect(pill == CGRect(x: 1206, y: 1410, width: 148, height: 30))
    }

    @Test func compactFrameCentredOnPlainNegativeOriginScreen() throws {
        let pill = try #require(NotchLayout.compactFrame(vertical, hovering: true))
        #expect(pill == CGRect(x: -794, y: 1410, width: 148, height: 30))
        let zone = try #require(NotchLayout.compactFrame(vertical, hovering: false))
        #expect(zone == CGRect(x: -794, y: 1436, width: 148, height: 4))
    }

    @Test func compactHiddenWhenMenuBarHidden() {
        let hidden = NotchScreen(id: 4, frame: external.frame, visibleFrame: external.frame)
        #expect(NotchLayout.compactFrame(hidden, hovering: false) == nil)
        #expect(NotchLayout.compactFrame(hidden, hovering: true, sharing: true) == nil)
        // A notch stays where it is, even with the menu bar hidden.
        var notched = builtIn
        notched.visibleFrame = notched.frame
        #expect(NotchLayout.compactFrame(notched, hovering: false) == NotchLayout.notch(builtIn))
    }

    @Test func panelFrameTopAnchoredAndCentredOnNotch() throws {
        let notch = try #require(NotchLayout.notch(builtIn))
        let content = CGSize(width: 500, height: 400)
        let panel = NotchLayout.panelFrame(builtIn, content: content)
        #expect(panel.maxY == builtIn.frame.maxY)
        #expect(panel.midX == notch.midX)
        #expect(panel.width == 500)
        #expect(panel.height == 38 + NotchLayout.gap + 400)
        #expect(NotchLayout.contentOffset(builtIn) == 41)
        let plain = NotchLayout.panelFrame(vertical, content: content)
        #expect(plain == CGRect(x: -970, y: 1440 - 433, width: 500, height: 433))
    }
}
