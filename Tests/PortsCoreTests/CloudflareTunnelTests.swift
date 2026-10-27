import Foundation
import Synchronization
import Testing

@testable import PortsCore

struct CloudflareTunnelTests {
    private func target(
        address: String = "127.0.0.1", kind: ServiceKind = .server,
        port: UInt16 = 5173, pid: Int32 = 123
    ) throws -> TunnelTarget {
        let endpoint = ListeningEndpoint(pid: pid, address: address, port: port)
        let service = ServiceRecord(
            process: ProcessRecord(
                identity: .init(pid: pid, startSeconds: 12),
                name: "node", executable: "/usr/bin/node"), kind: kind, framework: "Vite", endpoints: [endpoint])
        return try TunnelTarget(service: service, endpoint: endpoint)
    }

    @Test func originArgumentsPreserveIPv6AndNeverUseAShell() throws {
        let target = try target(address: "::1")
        let arguments = CloudflareTunnelManager.arguments(
            origin: target.origin,
            config: URL(fileURLWithPath: "/tmp/a directory's/config.yml"))
        #expect(arguments.contains("http://[::1]:5173"))
        #expect(arguments.last == "[::1]:5173")
        #expect(arguments.contains("/tmp/a directory's/config.yml"))
        #expect(arguments.contains("--no-autoupdate"))
        #expect(arguments.contains("--output"))
        #expect(!arguments.contains("--no-tls-verify"))
    }

    @Test func rejectsAgentsUnknownListenersAndHostnames() {
        #expect(throws: (any Error).self) { try target(kind: .agent) }
        #expect(throws: (any Error).self) { try target(kind: .listener) }
        #expect(throws: (any Error).self) { try target(address: "remote.example.com") }
        #expect(throws: (any Error).self) { try target(port: 0) }
    }

    @Test(arguments: ["192.168.1.5", "10.0.0.2", "localhost"])
    func rejectsNonLoopbackOrigins(_ address: String) {
        #expect(throws: TunnelError.unsupportedServer) { try target(address: address) }
    }

    @Test func knownNonHTTPServicesAreNeverTargets() {
        let process = ProcessRecord(
            identity: .init(pid: 123, startSeconds: 12), name: "postgres",
            executable: "/opt/homebrew/opt/postgresql@17/bin/postgres")
        let endpoint = ListeningEndpoint(pid: 123, address: "127.0.0.1", port: 5432)
        let postgres = ServiceRecord(
            process: process, kind: .server, framework: "PostgreSQL", endpoints: [endpoint],
            isKnownNonHTTP: ServiceClassifier().isKnownNonHTTP(process))
        #expect(throws: TunnelError.unsupportedServer) { try TunnelTarget(service: postgres, endpoint: endpoint) }
    }

    @Test func mapsWildcardToLoopbackAndSeparatesServerLifetimes() throws {
        let first = try target(address: "*")
        #expect(first.origin.absoluteString == "http://127.0.0.1:5173")
        #expect(first.id == TunnelKey(process: .init(pid: 123, startSeconds: 12), port: 5173))
        let reusedPID = TunnelKey(process: .init(pid: 123, startSeconds: 13), port: 5173)
        #expect(first.id != reusedPID)
    }

    @Test func oneKeyPerServerPortAcrossAddressFamilies() async throws {
        let service = ServiceRecord(
            process: ProcessRecord(
                identity: .init(pid: 123, startSeconds: 12), name: "node", executable: "/usr/bin/node"),
            kind: .server, framework: "Vite",
            endpoints: ["127.0.0.1", "::1", "*", "0.0.0.0", "::"].map {
                ListeningEndpoint(pid: 123, address: $0, port: 5173)
            } + [ListeningEndpoint(pid: 123, address: "127.0.0.1", port: 5174)])
        let targets = try service.endpoints.map { try TunnelTarget(service: service, endpoint: $0) }
        #expect(
            Set(targets.map(\.id)) == [.init(process: service.id, port: 5173), .init(process: service.id, port: 5174)])
        let fixture = try Fixture()
        defer { fixture.remove() }
        let manager = fixture.manager()
        let ipv4 = try await manager.start(targets[0])
        let ipv6 = try await manager.start(targets[1])
        #expect(targets[1].origin.absoluteString == "http://[::1]:5173")
        #expect(ipv4.sessionID == ipv6.sessionID)
        #expect(await manager.records().count == 1)
        try await manager.shutdown()
    }

    @Test func recordsAreOrderedByPort() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let manager = fixture.manager()
        let starts: [(port: UInt16, pid: Int32)] = [(8080, 123), (3000, 124), (3000, 123)]
        for start in starts { try await manager.start(target(port: start.port, pid: start.pid)) }
        let order = await manager.records().map { "\($0.id.port)/\($0.id.process.pid)" }
        #expect(order == ["3000/123", "3000/124", "8080/123"])
        try await manager.shutdown()
    }

    @Test func dualBoundServerSharesItsPrimaryLoopbackSocket() throws {
        let service = ServiceRecord(
            process: ProcessRecord(
                identity: .init(pid: 123, startSeconds: 12), name: "node", executable: "/usr/bin/node"),
            kind: .server, framework: "Vite",
            endpoints: ["::1", "127.0.0.1"].map { ListeningEndpoint(pid: 123, address: $0, port: 5173) })
        let target = try TunnelTarget(service: service, endpoint: try #require(service.ports.first).primary)
        #expect(target.origin.absoluteString == "http://127.0.0.1:5173")
    }

    @Test(arguments: [
        "http://valid.trycloudflare.com", "https://trycloudflare.com", "https://a.trycloudflare.com.evil.test",
        "https://a.trycloudflare.com@evil.test", "https://user@a.trycloudflare.com", "https://a.trycloudflare.com:444",
        "https://a.trycloudflare.com/path", "https://a.trycloudflare.com?other=x",
        "https://a.trycloudflare.com#fragment",
    ])
    func rejectsUntrustedURLs(_ url: String) { #expect(CloudflareLogState.validatedURL(url) == nil) }

    @Test func fragmentedBannerNeedsRegisteredConnectionAndTracksReconnects() {
        var state = CloudflareLogState()
        let banner = #"{"level":"info","message":"| https://some-small-preview.trycloudflare.com |"}"# + "\n"
        for byte in banner.utf8 { state.append(Data([byte])) }
        #expect(state.publicURL?.host == "some-small-preview.trycloudflare.com")
        #expect(!state.connected)
        state.append(Data((#"{"message":"Registered tunnel connection","connIndex":0}"# + "\n").utf8))
        #expect(state.connected)
        state.append(Data((#"{"message":"Unregistered tunnel connection","connIndex":0}"# + "\n").utf8))
        #expect(!state.connected)
        #expect(state.wasConnected)
        state.append(Data((#"{"message":"Registered tunnel connection","connIndex":0}"# + "\n").utf8))
        #expect(state.connected)
    }

    @Test func discardsOversizedLinesAndRecoversAtNextNewline() {
        var state = CloudflareLogState()
        state.append(Data((String(repeating: "x", count: 100_000) + " https://bad.trycloudflare.com\n").utf8))
        #expect(state.publicURL == nil)
        state.append(Data("https://valid.trycloudflare.com\n".utf8))
        #expect(state.publicURL?.host == "valid.trycloudflare.com")
    }

    @Test func validatorRequiresSameIdentityAndListener() throws {
        let target = try target()
        let original = target.id.process
        let reused = ProcessIdentity(pid: 123, startSeconds: 13)
        let otherPort = ListeningEndpoint(pid: 123, address: "127.0.0.1", port: 5174)
        func isCurrent(_ identities: [ProcessIdentity?], listeners: [ListeningEndpoint]?) -> Bool {
            TunnelOriginValidator(inspector: FakeInspector(identities), listeners: { _ in listeners })
                .isCurrent(target)
        }
        #expect(isCurrent([original, original], listeners: [otherPort, target.endpoint]))
        #expect(!isCurrent([reused, reused], listeners: [target.endpoint]))
        #expect(!isCurrent([nil, nil], listeners: [target.endpoint]))
        #expect(!isCurrent([original, original], listeners: [otherPort]))
        #expect(!isCurrent([original, original], listeners: nil))
        // The PID was reused while its sockets were read.
        #expect(!isCurrent([original, reused], listeners: [target.endpoint]))
    }

    @Test func nativeValidatorRejectsNonexistentProcess() throws {
        #expect(!TunnelOriginValidator().isCurrent(try target()))
    }

    @Test func nativeValidatorTracksOwnListener() throws {
        let listener = try bindListener("127.0.0.1")
        var isOpen = true
        defer { if isOpen { close(listener.descriptor) } }
        let process = try #require(NativeProcessInspector().process(pid: getpid()))
        let endpoint = ListeningEndpoint(pid: getpid(), address: "127.0.0.1", port: listener.port)
        let target = try TunnelTarget(
            service: ServiceRecord(process: process, kind: .server, framework: "Vite", endpoints: [endpoint]),
            endpoint: endpoint)
        #expect(TunnelOriginValidator().isCurrent(target))
        close(listener.descriptor)
        isOpen = false
        #expect(!TunnelOriginValidator().isCurrent(target))
    }

    @Test func duplicateClickSharesOneProcessAndStoppingAllowsAFreshSession() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let manager = fixture.manager()
        let target = try target()
        let first = try await manager.start(target)
        let duplicate = try await manager.start(target)
        #expect(first.sessionID == duplicate.sessionID)
        let ready = try await wait(manager, phase: .ready)
        #expect(ready?.publicURL?.host == "fixture-only.trycloudflare.com")
        try await manager.stop(target.id)
        let stopped = await manager.records().first
        #expect(stopped?.phase == .stopped)
        let next = try await manager.start(target)
        #expect(next.sessionID != first.sessionID)
        #expect(try await wait(manager, phase: .ready) != nil)
        try await manager.shutdown()
    }

    @Test func cancellingBeforeReadyDoesNotPublishTheBannerURL() async throws {
        let fixture = try Fixture(connected: false)
        defer { fixture.remove() }
        let manager = fixture.manager()
        let target = try target()
        try await manager.start(target)
        try await manager.stop(target.id)
        #expect(await manager.records().first?.phase == .stopped)
        try await manager.shutdown()
    }

    @Test func startupTimeoutStopsChildInsteadOfLeavingAnUnusableShare() async throws {
        let fixture = try Fixture(connected: false)
        defer { fixture.remove() }
        let manager = fixture.manager(timeout: 0.05)
        try await manager.start(target())
        let failed = try await wait(manager, phase: .failed)
        #expect(failed?.message != nil)
        try await manager.shutdown()
    }

    @Test func originDisappearanceAutomaticallyClosesSharingWithoutUIScans() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let origin = OriginFlag()
        let manager = fixture.manager(validate: { _ in origin.get() })
        try await manager.start(target())
        #expect(try await wait(manager, phase: .ready) != nil)
        origin.set(false)
        let ended = try await wait(manager, phase: .failed)
        #expect(ended?.message == "The server or port stopped. Sharing was closed.")
        try await manager.shutdown()
    }

    @Test func staleOriginNeverStartsAndShutdownRejectsNewShares() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let stale = fixture.manager(validate: { _ in false })
        await #expect(throws: (any Error).self) { try await stale.start(target()) }
        let manager = fixture.manager()
        try await manager.shutdown()
        await #expect(throws: (any Error).self) { try await manager.start(target()) }
    }

    @Test func missingClientNeverStarts() async throws {
        let manager = CloudflareTunnelManager(
            client: URL(fileURLWithPath: "/nonexistent/cloudflared"), runner: URL(fileURLWithPath: "/bin/sh"),
            timeout: 10, validateOrigin: { _ in true })
        await #expect(throws: TunnelError.missingClient) { try await manager.start(target()) }
        #expect(await manager.records().isEmpty)
    }

    @Test func notHTTPOriginNeverLaunches() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let manager = fixture.manager(probe: { _ in .notHTTP })
        await #expect(throws: TunnelError.notHTTP) { try await manager.start(target()) }
        #expect(await manager.records().isEmpty)
    }

    @Test func unreachableOriginIsServerChanged() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let manager = fixture.manager(probe: { _ in .unreachable })
        await #expect(throws: TunnelError.serverChanged) { try await manager.start(target()) }
        #expect(await manager.records().isEmpty)
    }

    @Test func inconclusiveProbeStillStarts() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let manager = fixture.manager(probe: { _ in .inconclusive })
        try await manager.start(target())
        #expect(try await wait(manager, phase: .ready) != nil)
        try await manager.shutdown()
    }

    @Test func concurrentStartsShareOneSession() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let gate = ProbeGate()
        let manager = fixture.manager(probe: { await gate.probe($0) })
        let target = try target()
        let first = Task { try await manager.start(target) }
        try await gate.waitUntilProbed(1)
        // The second click arrives while the first start waits for the probe.
        let second = Task { try await manager.start(target) }
        try await Task.sleep(for: .milliseconds(50))
        gate.open()
        let (firstRecord, secondRecord) = try await (first.value, second.value)
        #expect(firstRecord.sessionID == secondRecord.sessionID)
        #expect(gate.probed == [target.origin])
        #expect(await manager.records().count == 1)
        try await manager.shutdown()
    }

    @Test func shutdownDuringProbeRejectsTheStart() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let gate = ProbeGate()
        let manager = fixture.manager(probe: { await gate.probe($0) })
        let target = try target()
        let start = Task { try await manager.start(target) }
        try await gate.waitUntilProbed(1)
        try await manager.shutdown()
        gate.open()
        await #expect(throws: TunnelError.shuttingDown) { try await start.value }
        #expect(await manager.records().isEmpty)
    }

    @Test func stopAllDuringProbeRejectsTheStart() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let gate = ProbeGate()
        let manager = fixture.manager(probe: { await gate.probe($0) })
        let target = try target()
        let start = Task { try await manager.start(target) }
        try await gate.waitUntilProbed(1)
        // Switching to demo mode stops all shares without shutting the manager down.
        try await manager.stopAll()
        gate.open()
        await #expect(throws: CancellationError.self) { try await start.value }
        #expect(await manager.records().isEmpty)
        // Later starts still work.
        try await manager.start(target)
        #expect(await manager.records().count == 1)
        try await manager.shutdown()
    }

    @Test func stopAllKeepsFailureNotices() async throws {
        let fixture = try Fixture(failingPort: 3000)
        defer { fixture.remove() }
        let manager = fixture.manager()
        try await manager.start(target(port: 3000))
        try await manager.start(target(port: 5173))
        // Records are ordered by port, so the client that exited on its own comes first.
        let failed = try #require(try await wait(manager, phase: .failed))
        #expect(failed.message == "The Cloudflare connection ended. Please try again.")
        try await manager.stopAll()
        let records = await manager.records()
        #expect(records.map(\.phase) == [.failed, .stopped])
        #expect(records.first?.sessionID == failed.sessionID)
        #expect(records.first?.message == failed.message)
        try await manager.shutdown()
    }

    @Test func updatesStartWithSnapshotAndNeverRepeat() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let manager = fixture.manager()
        let recorder = SnapshotRecorder()
        let consumer = Task { for await records in await manager.updates() { recorder.append(records) } }
        defer { consumer.cancel() }
        try await recorder.waitUntil { $0.count == 1 }
        let target = try target()
        try await manager.start(target)
        try await recorder.waitUntil { $0.last?.first?.phase == .ready }
        try await manager.stop(target.id)
        try await recorder.waitUntil { $0.last?.first?.phase == .stopped }
        let snapshots = recorder.snapshots
        #expect(snapshots.first == [])
        #expect(zip(snapshots, snapshots.dropFirst()).allSatisfy { $0 != $1 })
        // A slow consumer may miss intermediate snapshots, never these.
        var expected: ArraySlice<TunnelPhase> = [.starting, .ready, .stopped]
        for phase in snapshots.compactMap(\.first?.phase) where phase == expected.first { expected.removeFirst() }
        #expect(expected.isEmpty)
        try await manager.shutdown()
    }

    @Test func cancellingConsumerRemovesObserver() async throws {
        let manager = CloudflareTunnelManager(
            client: URL(fileURLWithPath: "/nonexistent/cloudflared"), runner: URL(fileURLWithPath: "/bin/sh"),
            timeout: 10, validateOrigin: { _ in true })
        let consumer = Task { for await _ in await manager.updates() {} }
        #expect(try await eventually { await manager.observerCount == 1 })
        consumer.cancel()
        #expect(try await eventually { await manager.observerCount == 0 })
    }

    @Test func dismissPublishesRemoval() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let manager = fixture.manager()
        let recorder = SnapshotRecorder()
        let consumer = Task { for await records in await manager.updates() { recorder.append(records) } }
        defer { consumer.cancel() }
        let target = try target()
        try await manager.start(target)
        try await manager.stop(target.id)
        try await recorder.waitUntil { $0.last?.first?.phase == .stopped }
        await manager.dismiss(target.id)
        try await recorder.waitUntil { $0.last == [] }
        #expect(recorder.snapshots.last == [])
        try await manager.shutdown()
    }

    /// Polls for up to a second, because the stream removes its observer in a task of its own.
    private func eventually(_ condition: () async -> Bool) async throws -> Bool {
        for _ in 0..<100 {
            if await condition() { return true }
            try await Task.sleep(for: .milliseconds(10))
        }
        return false
    }

    private func wait(_ manager: CloudflareTunnelManager, phase: TunnelPhase) async throws -> TunnelRecord? {
        for _ in 0..<80 {
            if let record = await manager.records().first, record.phase == phase { return record }
            try await Task.sleep(for: .milliseconds(50))
        }
        return nil
    }

    private struct Fixture {
        let directory: URL
        let client: URL
        /// The client for `failingPort` exits at once without output, as if Cloudflare dropped it.
        init(connected: Bool = true, failingPort: UInt16? = nil) throws {
            directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            client = directory.appending(path: "fake-cloudflared")
            let ready =
                connected ? "printf '%s\\n' '{\"message\":\"Registered tunnel connection\",\"connIndex\":0}'" : ""
            let failing = failingPort.map { #"case "$*" in *"--url http://127.0.0.1:\#($0) "*) exit 3 ;; esac"# } ?? ""
            // read exits on the manager's private control-pipe EOF. No network or grandchild.
            try """
            #!/bin/sh
            [ "$PATH" = '/usr/bin:/bin' ] || exit 9
            \(failing)
            printf '%s\\n' '{"message":"https://fixture-only.trycloudflare.com"}'
            \(ready)
            read -r control
            exit 0
            """.write(to: client, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: client.path)
        }
        func manager(
            timeout: TimeInterval = 10,
            validate: @escaping @Sendable (TunnelTarget) -> Bool = { _ in true },
            probe: @escaping @Sendable (URL) async -> HTTPOriginVerdict = { _ in .http }
        ) -> CloudflareTunnelManager {
            CloudflareTunnelManager(
                client: client, runner: URL(fileURLWithPath: "/bin/sh"),
                timeout: timeout, validateOrigin: validate, probeOrigin: probe)
        }
        func remove() { try? FileManager.default.removeItem(at: directory) }
    }

    /// Answers identity lookups from the given sequence, then reports the process as gone.
    private final class FakeInspector: ProcessInspecting, @unchecked Sendable {
        private let lock = NSLock()
        private var identities: [ProcessIdentity?]
        init(_ identities: [ProcessIdentity?]) { self.identities = identities }
        func processes() throws -> [ProcessRecord] { [] }
        func process(pid: Int32) -> ProcessRecord? { nil }
        func identity(pid: Int32) -> ProcessIdentity? {
            lock.lock()
            defer { lock.unlock() }
            return identities.isEmpty ? nil : identities.removeFirst()
        }
    }

    /// Holds every probe until `open()` and answers HTTP, so a test can act while a start waits for the probe.
    private final class ProbeGate: Sendable {
        private let state = Mutex((probed: [URL](), waiters: [CheckedContinuation<Void, Never>](), isOpen: false))

        var probed: [URL] { state.withLock { $0.probed } }

        func probe(_ origin: URL) async -> HTTPOriginVerdict {
            await withCheckedContinuation { continuation in
                let isOpen = state.withLock { state in
                    state.probed.append(origin)
                    if !state.isOpen { state.waiters.append(continuation) }
                    return state.isOpen
                }
                if isOpen { continuation.resume() }
            }
            return .http
        }

        func open() {
            let waiters = state.withLock { state in
                state.isOpen = true
                defer { state.waiters.removeAll() }
                return state.waiters
            }
            for waiter in waiters { waiter.resume() }
        }

        /// Polls, because the probe runs in the manager's task, not the test's.
        func waitUntilProbed(_ count: Int) async throws {
            for _ in 0..<200 {
                if probed.count >= count { return }
                try await Task.sleep(for: .milliseconds(10))
            }
            Issue.record("The probe was not reached")
        }
    }

    /// Every snapshot a consumer received, in order.
    private final class SnapshotRecorder: Sendable {
        private let state = Mutex([[TunnelRecord]]())

        var snapshots: [[TunnelRecord]] { state.withLock { $0 } }

        func append(_ records: [TunnelRecord]) { state.withLock { $0.append(records) } }

        /// Polls, because the consumer runs in its own task.
        func waitUntil(_ condition: ([[TunnelRecord]]) -> Bool) async throws {
            for _ in 0..<400 {
                if condition(snapshots) { return }
                try await Task.sleep(for: .milliseconds(10))
            }
            Issue.record("The expected snapshot did not arrive")
        }
    }

    private final class OriginFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = true
        func get() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            return value
        }
        func set(_ next: Bool) {
            lock.lock()
            defer { lock.unlock() }
            value = next
        }
    }
}
