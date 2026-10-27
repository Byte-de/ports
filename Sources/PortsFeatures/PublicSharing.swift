import PortsCore

/// Which shares make a local server reachable from the internet right now. The menu bar and the notch show a globe
/// for them, so a share stays visible with every panel closed.
public enum PublicSharing {
    /// A share counts until its client has exited, including while it stops. The demo shows sample data only, so it
    /// never claims a share.
    public static func activeShares(records: [TunnelRecord], demoMode: Bool) -> [TunnelRecord] {
        demoMode ? [] : records.filter(\.phase.isActive)
    }
}
