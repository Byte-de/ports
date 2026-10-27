import PortsFeatures
import Testing

struct ScanCadenceTests {
    private func interval(_ preferred: Int, _ activity: ScanActivity) -> Duration {
        ScanCadence.interval(preferred: .seconds(preferred), activity: activity)
    }

    @Test func visibleKeepsThePreferredInterval() {
        #expect(interval(3, .visible) == .seconds(3))
        #expect(interval(2, .visible) == .seconds(2))
    }

    @Test func backgroundScansAtMostEveryFifteenSeconds() {
        #expect(interval(3, .background) == .seconds(15))
        #expect(interval(30, .background) == .seconds(30))
    }

    @Test func idleScansAtMostEveryMinute() {
        #expect(interval(3, .idle) == .seconds(60))
        #expect(interval(30, .idle) == .seconds(60))
    }

    private func scansNow(
        wasVisible: Bool = false, isVisible: Bool = true, hasScanned: Bool = true, age: Int
    ) -> Bool {
        ScanCadence.shouldScanNow(
            wasVisible: wasVisible, isVisible: isVisible, hasScanned: hasScanned, snapshotAge: .seconds(age),
            interval: .seconds(3))
    }

    @Test func appearingScansOnlyAStaleSnapshot() {
        #expect(scansNow(age: 4))
        #expect(scansNow(age: 3))
        #expect(!scansNow(age: 2))
        #expect(scansNow(hasScanned: false, age: 0))
    }

    @Test func onlyTheFirstVisibleSurfaceScans() {
        #expect(!scansNow(wasVisible: true, age: 30))
        #expect(!scansNow(isVisible: false, age: 30))
        #expect(!scansNow(wasVisible: true, isVisible: false, age: 30))
    }
}
