import Foundation
import PortsCore

/// When the opt-in weekly check asks GitHub, and which release the settings gear hints at. A manual check counts as
/// a check too, so it postpones the next weekly one.
public enum UpdateSchedule {
    /// Wall-clock time between two checks.
    public static let interval: TimeInterval = 7 * 24 * 60 * 60
    /// How often the schedule is looked at, so a due check runs at most this late, also after the Mac slept.
    public static let tick = Duration.seconds(6 * 60 * 60)
    /// The first look after launch, so a check never competes with the first scans.
    public static let launchDelay = Duration.seconds(20)

    /// A clock that moved back counts as due: waiting for it to catch up could skip checks for a long time.
    public static func isDue(lastCheck: Date?, now: Date) -> Bool {
        guard let lastCheck, now >= lastCheck else { return true }
        return now.timeIntervalSince(lastCheck) >= interval
    }

    /// The saved release newer than the installed version, unless that version or a newer one was dismissed. Saved
    /// strings that aren't a stable version, such as a prerelease, never count.
    public static func pendingRelease(latestKnown: String?, dismissed: String?, current: String) -> ReleaseVersion? {
        guard let latest = latestKnown.flatMap(ReleaseVersion.init), let current = ReleaseVersion(current),
            latest > current
        else { return nil }
        if let dismissed = dismissed.flatMap(ReleaseVersion.init), dismissed >= latest { return nil }
        return latest
    }
}
