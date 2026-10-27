import Foundation
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

    @Test func searchMatchesProjectFolderButNotLaunchdOrBundleFolders() {
        let services = [
            service(.server, pid: 1, title: "Vite", directory: "/Users/dev/shop/web"),
            service(.agent, pid: 2, title: "Codex", directory: "/Applications/Codex.app/Contents/Resources"),
            service(.agent, pid: 3, title: "Claude Code", directory: "/"),
        ]
        func pids(_ search: String) -> [Int32] {
            ServiceListing.visible(services, filter: .all, search: search, showsListeners: true).map(\.id.pid)
        }
        #expect(pids("shop/web") == [1])
        #expect(pids("/") == [1])
        #expect(pids("Contents").isEmpty)
    }

    @Test func blankSearchMatchesEverything() {
        #expect(pids(.all, search: "  ", showsListeners: true) == pids(.all, showsListeners: true))
    }

    @Test func projectsSitTogetherSortedByNameWithUnassignedLast() {
        let desktop = ServiceRecord(
            process: ProcessRecord(
                identity: .init(pid: 6, startSeconds: 100), name: "claude", executable: "/Applications/Claude.app",
                workingDirectory: "/Users/dev/claude"),
            kind: .agent, framework: "Agent", isDesktopApplication: true)
        let services = [
            service(.server, pid: 1, title: "Vite", directory: "/z/alpha"),
            service(.server, pid: 2, title: "Next.js", directory: "/a/zeta"),
            service(.agent, pid: 3, title: "Codex", directory: "/"),
            service(.server, pid: 4, title: "Astro", directory: "/b/beta"),
            service(.server, pid: 5, title: "Rails", directory: "/a/beta"),
            desktop,
            service(.listener, pid: 7, title: "postgres", directory: "/z/alpha/"),
            service(.server, pid: 8, title: "Hugo", directory: "/b/beta"),
        ]
        let grouped = ServiceListing.groupedByProject(services)
        #expect(
            grouped.map(\.projectDirectory) == [
                "/z/alpha", "/z/alpha", "/a/beta", "/b/beta", "/b/beta", "/a/zeta", nil, nil,
            ])
        // Inside a project and among services without one, the input order stays.
        #expect(grouped.map(\.id.pid) == [1, 7, 5, 4, 8, 2, 3, 6])
        #expect(ServiceListing.groupedByProject(grouped).map(\.id.pid) == grouped.map(\.id.pid))
        #expect(ServiceListing.groupedByProject([]).isEmpty)
    }

    @Test func primaryActionPerKind() {
        let vite = service(.server, pid: 42, title: "Vite", ports: [5173])
        let claude = service(.agent, pid: 7, title: "Claude", ports: [8787])
        let postgres = service(.listener, pid: 88, title: "postgres", ports: [5432])
        func action(_ service: ServiceRecord, http: Bool = false, activate: Bool = false) -> ServicePrimaryAction {
            ServicePrimaryAction.resolve(for: service, speaksHTTP: http, canActivate: activate)
        }
        #expect(action(vite, http: true) == .openURL(URL(string: "http://127.0.0.1:5173")!))
        #expect(action(vite) == .showDetails)
        #expect(action(service(.server, pid: 1, title: "Vite"), http: true) == .showDetails)
        #expect(action(postgres) == .showDetails)
        // An agent never opens its port: an app comes forward, a command-line session shows details.
        #expect(action(claude, http: true, activate: true) == .activate)
        #expect(action(claude, http: true) == .showDetails)
        // A paused process opens details, whatever it is.
        #expect(action(paused(vite), http: true) == .showDetails)
        #expect(action(paused(claude), activate: true) == .showDetails)
    }

    private func paused(_ service: ServiceRecord) -> ServiceRecord {
        let process = service.process
        return ServiceRecord(
            process: ProcessRecord(
                identity: process.identity, name: process.name, executable: process.executable,
                workingDirectory: process.workingDirectory, state: .paused),
            kind: service.kind, provider: service.provider, framework: service.framework,
            endpoints: service.endpoints)
    }
}
