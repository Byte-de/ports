import Darwin
import Foundation
import Testing

@testable import PortsCore

private struct FixtureInspector: ProcessInspecting {
    let records: [ProcessRecord]
    func processes() throws -> [ProcessRecord] { records }
    func process(pid: Int32) -> ProcessRecord? { records.first { $0.identity.pid == pid } }
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
