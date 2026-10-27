import Foundation
import PortsCore

/// Single source of truth for what the menu bar, notch and the Servers and Agents tabs call a server or an agent.
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

    /// Services of one project sit together and keep the input order. Projects sort by folder name as Finder does,
    /// then by path so two folders with the same name stay apart; services without a project come last.
    public static func groupedByProject(_ services: [ServiceRecord]) -> [ServiceRecord] {
        Dictionary(grouping: services, by: \.projectDirectory).values
            .sorted { projectPrecedes($0[0], $1[0]) }
            .flatMap { $0 }
    }

    private static func projectPrecedes(_ lhs: ServiceRecord, _ rhs: ServiceRecord) -> Bool {
        guard let left = lhs.projectDirectory, let right = rhs.projectDirectory else {
            return lhs.projectDirectory != nil
        }
        for order in [
            lhs.process.projectName.localizedStandardCompare(rhs.process.projectName),
            left.localizedStandardCompare(right),
        ] where order != .orderedSame {
            return order == .orderedAscending
        }
        return left < right
    }
}

/// What a click on a service row does: open what the row stands for when that is certain, otherwise show details.
public enum ServicePrimaryAction: Equatable, Sendable {
    case openURL(URL)
    case activate, showDetails

    /// A paused process opens details. An agent comes forward only when it is an app (`canActivate`): no terminal can
    /// attach to a running command-line session. A server opens in the browser only when it speaks HTTP.
    public static func resolve(for service: ServiceRecord, speaksHTTP: Bool, canActivate: Bool) -> Self {
        guard service.process.state == .running else { return .showDetails }
        if service.kind == .agent { return canActivate ? .activate : .showDetails }
        if speaksHTTP, let url = service.primaryEndpoint?.url { return .openURL(url) }
        return .showDetails
    }
}
