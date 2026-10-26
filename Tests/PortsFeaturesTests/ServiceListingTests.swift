import PortsCore
import PortsFeatures
import Testing

struct ServiceListingTests {
    private let services = [
        service(.server, pid: 42, title: "Vite", directory: "/Users/dev/commerce", ports: [5173]),
        service(.agent, pid: 7, title: "Claude Code", directory: "/Users/dev/api", ports: [8787]),
        service(.listener, pid: 88, title: "postgres", ports: [5432]),
        service(.server, pid: 120, title: "Next.js", directory: "/Users/dev/blog", ports: [3000]),
        service(.agent, pid: 9, title: "Codex", directory: "/Users/dev/tools"),
    ]

    private func pids(_ filter: ServiceFilter, search: String = "", showsListeners: Bool = false) -> [Int32] {
        ServiceListing.visible(services, filter: filter, search: search, showsListeners: showsListeners).map(\.id.pid)
    }

    @Test func listenersHiddenUntilEnabled() {
        #expect(pids(.all) == [42, 7, 120, 9])
        #expect(pids(.all, showsListeners: true) == [42, 7, 88, 120, 9])
    }

    @Test func agentWithPortCountsOnlyAsAgent() {
        #expect(pids(.agents) == [7, 9])
        #expect(!pids(.servers).contains(7))
        let counts = ServiceCounts(ServiceListing.visible(services, filter: .all, search: "", showsListeners: false))
        #expect((counts.agents, counts.servers, counts.total) == (2, 2, 4))
    }

    @Test func listenersCountAsServersWhenShown() {
        #expect(pids(.servers) == [42, 120])
        #expect(pids(.servers, showsListeners: true) == [42, 88, 120])
        let shown = ServiceCounts(ServiceListing.visible(services, filter: .all, search: "", showsListeners: true))
        #expect((shown.agents, shown.servers, shown.total) == (2, 3, 5))
    }

    @Test(arguments: ServiceFilter.allCases, [false, true])
    func invariants(filter: ServiceFilter, showsListeners: Bool) {
        let universe = ServiceListing.visible(services, filter: .all, search: "", showsListeners: showsListeners)
        let counts = ServiceCounts(universe)
        let expected =
            switch filter {
            case .all: counts.total
            case .servers: counts.servers
            case .agents: counts.agents
            }
        #expect(pids(filter, showsListeners: showsListeners).count == expected)
        // Servers and agents partition the visible list.
        let servers = Set(pids(.servers, showsListeners: showsListeners))
        let agents = Set(pids(.agents, showsListeners: showsListeners))
        #expect(servers.isDisjoint(with: agents))
        #expect(servers.union(agents) == Set(universe.map(\.id.pid)))
    }

    @Test(arguments: ["vite", "COMMERCE", " 5173 ", "42"])
    func searchMatchesTitleProjectPortPIDAndTrimsWhitespace(search: String) {
        #expect(pids(.all, search: search, showsListeners: true) == [42])
        #expect(pids(.agents, search: search, showsListeners: true).isEmpty)
    }

    @Test func blankSearchMatchesEverything() {
        #expect(pids(.all, search: "  ", showsListeners: true) == pids(.all, showsListeners: true))
    }
}
