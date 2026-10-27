import Synchronization
import Testing

@testable import PortsCore

/// A process table that changes between refreshes. Child lookups use the protocol default, which filters
/// `processes()` by parent PID and so lists zombies too.
private struct TreeInspector: ProcessInspecting {
    var table: [ProcessRecord]
    var sessions: [Int32: Int32] = [:]
    func processes() throws -> [ProcessRecord] { table }
    func process(pid: Int32) -> ProcessRecord? { table.first { $0.identity.pid == pid } }
    func sessionID(pid: Int32) -> Int32? { sessions[pid] }
}

/// Swaps its table for `after` when the root's identity is checked, which falls between reading the known descendants
/// and walking the tree.
private final class RacingInspector: ProcessInspecting, Sendable {
    private let table: Mutex<[ProcessRecord]>
    private let after: [ProcessRecord]
    private let sessions: [Int32: Int32]
    init(before: [ProcessRecord], after: [ProcessRecord], sessions: [Int32: Int32]) {
        table = Mutex(before)
        self.after = after
        self.sessions = sessions
    }
    func processes() throws -> [ProcessRecord] { table.withLock { $0 } }
    func process(pid: Int32) -> ProcessRecord? { table.withLock { $0.first { $0.identity.pid == pid } } }
    func identity(pid: Int32) -> ProcessIdentity? {
        table.withLock { $0 = after }
        return process(pid: pid).flatMap { $0.state == .exited ? nil : $0.identity }
    }
    func sessionID(pid: Int32) -> Int32? { sessions[pid] }
}

private func record(_ pid: Int32, parent: Int32, start: UInt64 = 100, state: ProcessState = .running) -> ProcessRecord {
    ProcessRecord(
        identity: .init(pid: pid, startSeconds: start), parentPID: parent, name: "node",
        executable: "/opt/homebrew/bin/node", state: state)
}

private let root = record(100, parent: 50)

private func refresh(
    _ inspector: some ProcessInspecting, known: [ProcessIdentity: ProcessRecord] = [:], session: Int32? = nil
) -> [ProcessIdentity: ProcessRecord] {
    JobTree.refresh(known: known, root: root.identity, session: session, inspector: inspector)
}

private func pids(_ tree: [ProcessIdentity: ProcessRecord]) -> [Int32] { tree.keys.map(\.pid).sorted() }

struct LaunchTreeTests {
    @Test func walksRootChildAndGrandchild() {
        let inspector = TreeInspector(table: [
            root, record(101, parent: 100), record(102, parent: 101), record(200, parent: 1), record(201, parent: 50),
        ])
        #expect(pids(refresh(inspector)) == [101, 102])
    }

    @Test func tracksGrandchildAfterReparenting() {
        var inspector = TreeInspector(table: [root, record(101, parent: 100), record(102, parent: 101)])
        let tree = refresh(inspector)
        // The child exits and launchd adopts the grandchild.
        inspector.table = [root, record(102, parent: 1)]
        let refreshed = refresh(inspector, known: tree)
        #expect(pids(refreshed) == [102])
        #expect(refreshed.values.first?.parentPID == 1)
    }

    @Test func findsNewChildOfReparentedDescendant() {
        var inspector = TreeInspector(table: [root, record(101, parent: 100)])
        var tree = refresh(inspector)
        // The root exits, so only the reparented descendant leads to the new child.
        inspector.table = [record(101, parent: 1), record(102, parent: 101, start: 200)]
        tree = refresh(inspector, known: tree)
        #expect(pids(tree) == [101, 102])
        inspector.table.append(record(103, parent: 102, start: 300))
        #expect(pids(refresh(inspector, known: tree)) == [101, 102, 103])
    }

    @Test func dropsReusedPIDWithNewStartTime() {
        var inspector = TreeInspector(table: [root, record(101, parent: 100), record(102, parent: 101)])
        let tree = refresh(inspector)
        // Both exit; an unrelated process with a child reuses PID 101.
        inspector.table = [root, record(101, parent: 1, start: 300), record(103, parent: 101, start: 301)]
        #expect(refresh(inspector, known: tree).isEmpty)
        // A reused root PID does not adopt the new process's children either.
        inspector.table = [record(100, parent: 50, start: 300), record(104, parent: 100, start: 301)]
        #expect(refresh(inspector).isEmpty)
    }

    @Test func ignoresZombies() {
        var inspector = TreeInspector(table: [root, record(101, parent: 100, state: .exited), record(102, parent: 100)])
        let tree = refresh(inspector)
        #expect(pids(tree) == [102])
        inspector.table = [root, record(102, parent: 100, state: .exited)]
        #expect(refresh(inspector, known: tree).isEmpty)
    }

    @Test func dropsDetachedDaemonWithItsChildren() {
        var inspector = TreeInspector(
            table: [root, record(101, parent: 100), record(102, parent: 100), record(103, parent: 101)],
            sessions: [100: 7, 101: 7, 102: 7, 103: 7])
        let tree = refresh(inspector, session: 7)
        #expect(pids(tree) == [101, 102, 103])
        // The root exits. 101 starts its own session as a daemon; 102 is adopted by launchd but stays in the job's.
        inspector.table = [record(101, parent: 1), record(102, parent: 1), record(103, parent: 101)]
        inspector.sessions = [101: 9, 102: 7, 103: 9]
        #expect(pids(refresh(inspector, known: tree, session: 7)) == [102])
        // Without a recorded session, nothing counts as detached.
        #expect(pids(refresh(inspector, known: tree)) == [101, 102, 103])
    }

    @Test func keepsGrandchildReparentedDuringRefresh() {
        let child = record(101, parent: 100)
        let grandchild = record(102, parent: 101)
        // The child exits after both were read, so launchd has adopted the grandchild before the walk.
        let inspector = RacingInspector(
            before: [root, child, grandchild], after: [root, record(102, parent: 1)],
            sessions: [100: 7, 101: 7, 102: 7])
        let tree = refresh(inspector, known: [child.identity: child, grandchild.identity: grandchild], session: 7)
        #expect(pids(tree).contains(102))
        #expect(pids(refresh(inspector, known: tree, session: 7)) == [102])
    }
}
