/// What can see the scan results. Only an open window, menu panel or expanded notch is visible; the compact notch
/// pill and the menu bar label are background, because they show counts that may lag a little.
public enum ScanActivity: String, Sendable {
    case visible, background, idle
}

/// How often the scan loop runs. Scanning at the preferred rate only while someone can look keeps the app cheap in
/// the background, and still notices services that start or stop.
public enum ScanCadence {
    /// Nothing visible: counts still follow within seconds.
    public static let backgroundFloor = Duration.seconds(15)
    /// Displays asleep, system sleep or an inactive session: nobody can see a count.
    public static let idleFloor = Duration.seconds(60)

    public static func interval(preferred: Duration, activity: ScanActivity) -> Duration {
        switch activity {
        case .visible: preferred
        case .background: max(preferred, backgroundFloor)
        case .idle: max(preferred, idleFloor)
        }
    }

    /// The first surface to appear scans at once unless the last scan is younger than the preferred interval, so it
    /// never opens on a background-age list and quickly reopening it adds no scan.
    public static func shouldScanNow(
        wasVisible: Bool, isVisible: Bool, hasScanned: Bool, snapshotAge: Duration, interval: Duration
    ) -> Bool {
        !wasVisible && isVisible && (!hasScanned || snapshotAge >= interval)
    }
}
