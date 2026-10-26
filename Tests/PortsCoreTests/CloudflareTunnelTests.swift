import Foundation
import Testing

@testable import PortsCore

@Suite(.enabled(if: ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 15, "Cloudflare benötigt macOS 15"))
struct CloudflareTunnelTests {
    private func target(
        address: String = "127.0.0.1", kind: ServiceKind = .server,
        port: UInt16 = 5173
    ) throws -> TunnelTarget {
        let endpoint = ListeningEndpoint(pid: 123, address: address, port: port)
        let service = ServiceRecord(
            process: ProcessRecord(
                identity: .init(pid: 123, startSeconds: 12),
                name: "node", executable: "/usr/bin/node"), kind: kind, framework: "Vite", endpoints: [endpoint])
        return try TunnelTarget(service: service, endpoint: endpoint)
    }

    @Test func originArgumentsPreserveIPv6AndNeverUseAShell() throws {
        let target = try target(address: "::1")
        let arguments = CloudflareTunnelManager.arguments(
            origin: target.id.origin,
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

    @Test func mapsWildcardToLoopbackAndSeparatesServerLifetimes() throws {
        let first = try target(address: "*")
        #expect(first.id.origin.absoluteString == "http://127.0.0.1:5173")
        let reusedPID = TunnelKey(process: .init(pid: 123, startSeconds: 13), origin: first.id.origin)
        #expect(first.id != reusedPID)
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

    @Test func nativeValidatorRejectsNonexistentProcess() throws {
        #expect(!TunnelOriginValidator().isCurrent(try target()))
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
        #expect(ended?.message?.contains("Port beendet") == true)
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
        init(connected: Bool = true) throws {
            directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            client = directory.appending(path: "fake-cloudflared")
            let ready =
                connected ? "printf '%s\\n' '{\"message\":\"Registered tunnel connection\",\"connIndex\":0}'" : ""
            // read exits on the manager's private control-pipe EOF. No network or grandchild.
            try """
            #!/bin/sh
            [ "$PATH" = '/usr/bin:/bin' ] || exit 9
            printf '%s\\n' '{"message":"https://fixture-only.trycloudflare.com"}'
            \(ready)
            read -r control
            exit 0
            """.write(to: client, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: client.path)
        }
        func manager(
            timeout: TimeInterval = 10,
            validate: @escaping @Sendable (TunnelTarget) -> Bool = { _ in true }
        ) -> CloudflareTunnelManager {
            CloudflareTunnelManager(
                client: client, runner: URL(fileURLWithPath: "/bin/sh"),
                timeout: timeout, validateOrigin: validate)
        }
        func remove() { try? FileManager.default.removeItem(at: directory) }
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
