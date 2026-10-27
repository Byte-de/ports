import Foundation
import PortsCore

/// Single source of truth for what the menu bar, header, notch and the Services filter call a server or an agent.
/// Servers and agents partition the list: a server is everything that is not an agent, so dev servers
/// and, when shown, other TCP listeners. An agent that owns a port stays an agent.
public enum ServiceFilter: String, CaseIterable, Sendable {
    case all, servers, agents

    public func includes(_ service: ServiceRecord) -> Bool {
        switch self {
        case .all: true
        case .servers: service.kind != .agent
        case .agents: service.kind == .agent
        }
    }
}

/// Counts over the visible list, so every surface shows the numbers the filter produces.
public struct ServiceCounts: Equatable, Sendable {
    public let agents: Int
    public let servers: Int
    public var total: Int { agents + servers }

    public init(_ visible: [ServiceRecord]) {
        agents = visible.count { ServiceFilter.agents.includes($0) }
        servers = visible.count { ServiceFilter.servers.includes($0) }
    }
}

public enum ServiceListing {
    /// Keeps the input order. Listeners stay hidden unless the user opted into all TCP listeners.
    public static func visible(
        _ services: [ServiceRecord], filter: ServiceFilter, search: String, showsListeners: Bool
    ) -> [ServiceRecord] {
        services.filter {
            ($0.kind != .listener || showsListeners) && filter.includes($0) && matches($0, search: search)
        }
    }

    /// Surrounding whitespace is ignored, and an empty search matches every service.
    public static func matches(_ service: ServiceRecord, search: String) -> Bool {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return true }
        let fields =
            [
                service.title, service.process.projectName, service.projectDirectory ?? "",
                String(service.id.pid),
            ]
            + service.endpoints.map { String($0.port) }
        return fields.contains { $0.localizedCaseInsensitiveContains(query) }
    }
}
