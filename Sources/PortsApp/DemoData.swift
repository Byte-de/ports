import Foundation
import PortsCore

enum DemoData {
    static var snapshot: ScanSnapshot {
        let base = "/Users/demo/Developer"
        let definitions: [(String, String, String, ServiceKind, String, UInt16?, Double, UInt64)] = [
            ("Claude Code", "claude", "commerce-web", .agent, "asterisk", nil, 12.4, 248),
            ("Codex", "codex", "design-system", .agent, "command", nil, 8.2, 186),
            ("Cursor", "cursor-agent", "api-gateway", .agent, "cursorarrow", nil, 0.4, 312),
            ("Next.js", "next", "commerce-web", .server, "server.rack", 3000, 2.8, 164),
            ("Vite", "vite", "design-system", .server, "bolt", 5173, 0.6, 82),
            ("FastAPI", "uvicorn", "api-gateway", .server, "bolt.horizontal", 8000, 1.2, 58),
        ]
        let services = definitions.enumerated().map { index, item in
            let pid = Int32(40_100 + index)
            return ServiceRecord(
                process: ProcessRecord(
                    identity: ProcessIdentity(
                        pid: pid, startSeconds: UInt64(Date().timeIntervalSince1970) - UInt64(600 + index * 340)),
                    name: item.1, executable: "/opt/homebrew/bin/\(item.1)",
                    arguments: [item.1, item.3 == .agent ? "" : "dev"].filter { !$0.isEmpty },
                    workingDirectory: "\(base)/\(item.2)", state: index == 2 ? .paused : .running,
                    residentBytes: item.7 * 1_048_576),
                kind: item.3,
                provider: item.3 == .agent ? AgentProvider(id: item.1, name: item.0, symbol: item.4) : nil,
                framework: item.0,
                endpoints: item.5.map { [ListeningEndpoint(pid: pid, address: "127.0.0.1", port: $0)] } ?? [],
                cpuPercent: item.6
            )
        }
        return ScanSnapshot(services: services, processCount: 284)
    }
}
