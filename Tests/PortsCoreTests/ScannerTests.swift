import Testing

@testable import PortsCore

private struct SnapshotInspector: ProcessInspecting {
    let initial: [ProcessRecord]
    let current: [ProcessRecord]
    func processes() throws -> [ProcessRecord] { initial }
    func process(pid: Int32) -> ProcessRecord? { current.first { $0.identity.pid == pid } }
}

private struct FixtureListeners: ListenerDiscovering {
    var endpoints: [ListeningEndpoint] = []
    var failure: MonitorError?
    func listeners() throws -> [ListeningEndpoint] {
        if let failure { throw failure }
        return endpoints
    }
}

struct ScannerTests {
    @Test func reconcilesExecBetweenProcessAndSocketSnapshots() async throws {
        let shell = process("/bin/zsh")
        let server = process("/usr/local/bin/node", arguments: ["node", "/app/node_modules/vite/bin/vite.js"])
        let scanner = ProcessScanner(
            inspector: SnapshotInspector(initial: [shell], current: [server]),
            listenerDiscovery: FixtureListeners(endpoints: [.init(pid: 42, address: "127.0.0.1", port: 5173)])
        )
        let snapshot = try await scanner.scan()
        #expect(snapshot.services.count == 1)
        #expect(snapshot.services.first?.process.executable == server.executable)
        #expect(snapshot.services.first?.framework == "Vite")
    }

    @Test func discardsSocketsWhenPIDWasReused() async throws {
        let scanner = ProcessScanner(
            inspector: SnapshotInspector(
                initial: [process("/usr/bin/node", seconds: 100)],
                current: [process("/bin/other", seconds: 101)]),
            listenerDiscovery: FixtureListeners(endpoints: [.init(pid: 42, address: "*", port: 3000)])
        )
        #expect(try await scanner.scan().services.isEmpty)
    }

    @Test func collapsesProviderWrapperAndItsChild() async throws {
        let parent = process("/usr/bin/node", arguments: ["node", "/lib/@openai/codex/bin/codex.js"], pid: 41)
        let child = process("/opt/codex", pid: 42, parent: 41)
        let scanner = ProcessScanner(
            inspector: SnapshotInspector(initial: [parent, child], current: [parent, child]),
            listenerDiscovery: FixtureListeners())
        let snapshot = try await scanner.scan()
        #expect(snapshot.services.map(\.id.pid) == [41])
    }

    @Test func reportsListenerFailureWithoutDroppingAgents() async throws {
        let agent = process("/opt/bin/claude")
        let scanner = ProcessScanner(
            inspector: SnapshotInspector(initial: [agent], current: [agent]),
            listenerDiscovery: FixtureListeners(failure: .timedOut))
        let snapshot = try await scanner.scan()
        #expect(snapshot.services.count == 1)
        #expect(snapshot.warning != nil)
    }
}
