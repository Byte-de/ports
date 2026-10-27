import Foundation
import PortsFeatures
import Testing

@testable import PortsCore

struct PublicSharingTests {
    private func record(_ phase: TunnelPhase, port: UInt16) throws -> TunnelRecord {
        let server = service(.server, pid: 40, title: "Vite", ports: [port])
        let target = try TunnelTarget(service: server, endpoint: try #require(server.endpoints.first))
        return TunnelRecord(target: target, sessionID: UUID(), phase: phase)
    }

    @Test func activeSharesKeepEveryPhaseUntilTheClientExits() throws {
        let phases: [TunnelPhase] = [.starting, .ready, .stopped, .reconnecting, .failed, .stopping]
        let records = try phases.enumerated().map { try record($1, port: 3000 + UInt16($0)) }
        let active = PublicSharing.activeShares(records: records, demoMode: false)
        #expect(active.map(\.phase) == [.starting, .ready, .reconnecting, .stopping])
        #expect(active.map(\.target.endpoint.port) == [3000, 3001, 3003, 3005])
    }

    @Test func endedSharesAreNotActive() throws {
        let records = try [record(.stopped, port: 3000), record(.failed, port: 3001)]
        #expect(PublicSharing.activeShares(records: records, demoMode: false).isEmpty)
        #expect(PublicSharing.activeShares(records: [], demoMode: false).isEmpty)
    }

    @Test func demoModeNeverShowsAShare() throws {
        let records = try [record(.ready, port: 3000), record(.starting, port: 3001)]
        #expect(PublicSharing.activeShares(records: records, demoMode: true).isEmpty)
    }
}
