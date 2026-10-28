import Foundation
import PortsCore
import PortsFeatures
import Testing

struct UpdateScheduleTests {
    private let checked = Date(timeIntervalSinceReferenceDate: 800_000_000)

    @Test func dueWithoutAnEarlierCheck() {
        #expect(UpdateSchedule.isDue(lastCheck: nil, now: checked))
    }

    @Test func dueAfterSevenDays() {
        #expect(UpdateSchedule.interval == 7 * 24 * 60 * 60)
        #expect(!UpdateSchedule.isDue(lastCheck: checked, now: checked))
        #expect(!UpdateSchedule.isDue(lastCheck: checked, now: checked + UpdateSchedule.interval - 1))
        #expect(UpdateSchedule.isDue(lastCheck: checked, now: checked + UpdateSchedule.interval))
        #expect(UpdateSchedule.isDue(lastCheck: checked, now: checked + 30 * 24 * 60 * 60))
    }

    @Test func dueWhenTheClockMovedBack() {
        #expect(UpdateSchedule.isDue(lastCheck: checked, now: checked - 1))
        #expect(UpdateSchedule.isDue(lastCheck: checked, now: checked - UpdateSchedule.interval * 2))
    }

    @Test func tickTimings() {
        #expect(UpdateSchedule.tick == .seconds(6 * 60 * 60))
        #expect(UpdateSchedule.launchDelay == .seconds(20))
    }

    private func pending(_ latest: String?, dismissed: String? = nil, current: String = "1.0.0") -> String? {
        UpdateSchedule.pendingRelease(latestKnown: latest, dismissed: dismissed, current: current)?.string
    }

    @Test func pendingWhenNewer() {
        #expect(pending("1.0.1") == "1.0.1")
        #expect(pending("1.10.0", current: "1.9.0") == "1.10.0")
        #expect(pending("v2.0.0") == "2.0.0")
    }

    @Test func nothingPendingWhenEqualOrOlder() {
        #expect(pending("1.0.0") == nil)
        #expect(pending("0.9.0") == nil)
        #expect(pending(nil) == nil)
    }

    @Test func dismissedVersionHidesOnlyUpToItself() {
        #expect(pending("1.1.0", dismissed: "1.1.0") == nil)
        #expect(pending("1.1.0", dismissed: "1.2.0") == nil)
        // A newer release than the dismissed one shows again.
        #expect(pending("1.2.0", dismissed: "1.1.0") == "1.2.0")
    }

    @Test(arguments: ["", "1.1", "1.1.0-beta.1", "1.1.0+5", "v01.1.0", "latest"])
    func ignoresInvalidOrPrereleaseVersions(value: String) {
        #expect(pending(value) == nil)
        #expect(pending("1.1.0", current: value) == nil)
        // A dismissal that can't be read dismisses nothing.
        #expect(pending("1.1.0", dismissed: value) == "1.1.0")
    }
}
