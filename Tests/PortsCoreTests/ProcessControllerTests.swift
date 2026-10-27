import Darwin
import Foundation
import Testing

@testable import PortsCore

private struct FixtureInspector: ProcessInspecting {
    let records: [ProcessRecord]
    func processes() throws -> [ProcessRecord] { records }
    func process(pid: Int32) -> ProcessRecord? { records.first { $0.identity.pid == pid } }
}

/// Records can change after the controller is created, and every read is counted.
private final class CountingInspector: ProcessInspecting, @unchecked Sendable {
    private let lock = NSLock()
    private var current: [ProcessRecord]
    private var count = 0
    init(_ records: [ProcessRecord]) { current = records }
    func processes() throws -> [ProcessRecord] {
        lock.lock()
        defer { lock.unlock() }
        count += 1
        return current
    }
    func process(pid: Int32) -> ProcessRecord? {
        lock.lock()
        defer { lock.unlock() }
        count += 1
        return current.first { $0.identity.pid == pid }
    }
    var records: [ProcessRecord] {
        get {
            lock.lock()
            defer { lock.unlock() }
            return current
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            current = newValue
        }
    }
    var reads: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
}

private final class SignalSpy: SignalSending, @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [(Int32, Int32)] = []
    func send(_ signal: Int32, to pid: Int32) throws {
        lock.lock()
        defer { lock.unlock() }
        calls.append((signal, pid))
    }
    var signals: [Int32] {
        lock.lock()
        defer { lock.unlock() }
        return calls.map(\.0)
    }
}

struct ProcessControllerTests {
    @Test func refusesReusedPIDIncludingMicrosecondDifference() {
        let expected = process("/usr/bin/node", microseconds: 1)
        let live = process("/usr/bin/node", microseconds: 2)
        let spy = SignalSpy()
        let controller = ProcessController(
            inspector: FixtureInspector(records: [live]), sender: spy, currentPID: 999, currentUID: 501)
        #expect(throws: MonitorError.processChanged) { try controller.perform(.terminate, on: expected) }
        #expect(spy.signals.isEmpty)
    }

    @Test func refusesExecChangeUnderSamePID() {
        let expected = process("/usr/bin/node")
        let live = process("/bin/zsh")
        let spy = SignalSpy()
        let controller = ProcessController(
            inspector: FixtureInspector(records: [live]), sender: spy, currentPID: 999, currentUID: 501)
        #expect(throws: MonitorError.processChanged) { try controller.perform(.terminate, on: expected) }
        #expect(spy.signals.isEmpty)
    }

    @Test func protectsSelfAncestorsDesktopAndOtherUsers() {
        let parent = process("/bin/zsh", pid: 50)
        let own = process("/tmp/Byte Ports", pid: 999, parent: 50)
        let targets = [
            parent, own, process("/bin/launchd", pid: 1), process("/tmp/node", uid: 0),
            process("/Applications/Codex.app/Contents/MacOS/Codex"), process("/System/test"),
        ]
        let spy = SignalSpy()
        let controller = ProcessController(
            inspector: FixtureInspector(records: [own, parent]), sender: spy, currentPID: 999, currentUID: 501)
        for target in targets {
            #expect(throws: MonitorError.protectedProcess) { try controller.perform(.terminate, on: target) }
        }
        #expect(spy.signals.isEmpty)
    }

    @Test func ancestorProtectionFollowsIdentityNotPID() throws {
        let own = process("/tmp/Byte Ports", pid: 999, parent: 50)
        let inspector = CountingInspector([own, process("/bin/zsh", pid: 50)])
        let spy = SignalSpy()
        let controller = ProcessController(inspector: inspector, sender: spy, currentPID: 999, currentUID: 501)
        // The parent shell exited and an unrelated process reused its PID.
        let reused = process("/bin/sleep", pid: 50, seconds: 200)
        inspector.records = [own, reused]
        try controller.perform(.pause, on: reused)
        #expect(spy.signals == [SIGSTOP])
    }

    @Test func controllabilityDoesNotReadProcesses() {
        let parent = process("/bin/zsh", pid: 50)
        let inspector = CountingInspector([process("/tmp/Byte Ports", pid: 999, parent: 50), parent])
        let controller = ProcessController(inspector: inspector, sender: SignalSpy(), currentPID: 999, currentUID: 501)
        let readsAfterInit = inspector.reads
        let unrelated = process("/bin/sleep")
        for index in 0..<100 {
            #expect(controller.isControllable(index.isMultiple(of: 2) ? unrelated : parent) == index.isMultiple(of: 2))
        }
        #expect(inspector.reads == readsAfterInit)
    }

    @Test func resumesPausedProcessAfterTerminationSignal() throws {
        let target = process("/bin/sleep", state: .paused)
        let spy = SignalSpy()
        let controller = ProcessController(
            inspector: FixtureInspector(records: [target]), sender: spy, currentPID: 999, currentUID: 501)
        try controller.perform(.terminate, on: target)
        #expect(spy.signals == [SIGTERM, SIGCONT])
    }

    @Test func refusesVanishedProcesses() {
        let spy = SignalSpy()
        let controller = ProcessController(
            inspector: FixtureInspector(records: []), sender: spy, currentPID: 999, currentUID: 501)
        #expect(throws: MonitorError.processChanged) { try controller.perform(.pause, on: process("/bin/sleep")) }
        #expect(spy.signals.isEmpty)
    }

    @Test func ownedMemberMaySignalAppBundleExecutable() throws {
        let target = process("/Applications/Codex.app/Contents/MacOS/Codex")
        let spy = SignalSpy()
        let controller = ProcessController(
            inspector: FixtureInspector(records: [target]), sender: spy, currentPID: 999, currentUID: 501)
        #expect(throws: MonitorError.protectedProcess) { try controller.perform(.terminate, on: target) }
        try controller.signalOwnedJobMember(SIGTERM, target)
        try controller.signalOwnedJobMember(SIGKILL, target)
        #expect(spy.signals == [SIGTERM, SIGKILL])
    }

    @Test func ownedMemberStillRefusesSystemOtherUserSelfAndReusedPID() {
        let parent = process("/bin/zsh", pid: 50)
        let own = process("/tmp/Byte Ports", pid: 999, parent: 50)
        let protected = [
            parent, own, process("/bin/launchd", pid: 1), process("/tmp/node", uid: 0), process("/System/test"),
            process("/usr/libexec/test"),
        ]
        let reused = process("/usr/bin/node", pid: 60, microseconds: 1)
        let spy = SignalSpy()
        let controller = ProcessController(
            inspector: FixtureInspector(records: [own, parent, process("/usr/bin/node", pid: 60, microseconds: 2)]),
            sender: spy, currentPID: 999, currentUID: 501)
        for target in protected {
            #expect(throws: MonitorError.protectedProcess) { try controller.signalOwnedJobMember(SIGKILL, target) }
        }
        #expect(throws: MonitorError.processChanged) { try controller.signalOwnedJobMember(SIGKILL, reused) }
        #expect(spy.signals.isEmpty)
    }

    @Test func ownedKillOnPausedSendsOnlyKill() throws {
        let target = process("/bin/sleep", state: .paused)
        let spy = SignalSpy()
        let controller = ProcessController(
            inspector: FixtureInspector(records: [target]), sender: spy, currentPID: 999, currentUID: 501)
        try controller.signalOwnedJobMember(SIGKILL, target)
        #expect(spy.signals == [SIGKILL])
        // A paused process needs SIGCONT to act on SIGTERM.
        try controller.signalOwnedJobMember(SIGTERM, target)
        #expect(spy.signals == [SIGKILL, SIGTERM, SIGCONT])
    }

    @Test func sendsOnlyRequestedSignalToVerifiedProcess() throws {
        let target = process("/bin/sleep")
        let spy = SignalSpy()
        let controller = ProcessController(
            inspector: FixtureInspector(records: [target]), sender: spy, currentPID: 999, currentUID: 501)
        try controller.perform(.pause, on: target)
        try controller.perform(.resume, on: target)
        #expect(spy.signals == [SIGSTOP, SIGCONT])
    }
}
