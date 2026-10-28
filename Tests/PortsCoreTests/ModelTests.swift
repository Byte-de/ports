import Testing

@testable import PortsCore

private func record(
    _ kind: ServiceKind, pid: Int32, title: String, directory: String?, endpoints: [ListeningEndpoint] = []
) -> ServiceRecord {
    ServiceRecord(
        process: ProcessRecord(
            identity: .init(pid: pid, startSeconds: 100), name: title.lowercased(), executable: "/bin/\(title)",
            workingDirectory: directory),
        kind: kind, framework: title, endpoints: endpoints)
}

private func ports(_ sockets: [(address: String, port: UInt16)]) -> [ServicePort] {
    ServicePort.group(sockets.map { ListeningEndpoint(pid: 1, address: $0.address, port: $0.port) })
}

struct ModelTests {
    @Test(
        arguments: [
            nil, "", "/", "//",
            "/Applications/ChatGPT.app/Contents/Resources", "/Applications/Codex.app/Contents",
            "/Users/a/dev/Tool.APP/contents/MacOS",
            "/Library/Application Support/x", "/Library/Apple/System", "/Library/Caches",
            "/Users/a/Library/Application Support/Code", "/Users/a/Library/Containers/x",
            "/Users/a/Library/Group Containers/x", "/Users/a/Library/Caches/x", "/Users/a/Library/Preferences",
            "/Users/a/Library/Saved Application State/x", "/Users/a/Library/Developer/Xcode/DerivedData/App-abc/Build",
            "/Users/a/library/containers/x/",
        ] as [String?])
    func launchdBundlesAndAppDataAreNoProject(path: String?) {
        #expect(ProjectFolder.directory(for: path, home: "/Users/a") == nil)
    }

    @Test(arguments: [
        ("/tmp/project", "/tmp/project"),
        ("/Users/a/dev/site/", "/Users/a/dev/site"),
        ("/Users/a", "/Users/a"),
        ("/Users/a/", "/Users/a"),
        ("/Users/a/Library/CloudStorage/Dropbox/site", "/Users/a/Library/CloudStorage/Dropbox/site"),
        (
            "/Users/a/Library/Mobile Documents/com~apple~CloudDocs/site",
            "/Users/a/Library/Mobile Documents/com~apple~CloudDocs/site"
        ),
        ("/Users/a/Library/Developer/tools", "/Users/a/Library/Developer/tools"),
        ("/Users/a/dev/acme.app", "/Users/a/dev/acme.app"),
        ("/Users/a/dev/acme.app/src", "/Users/a/dev/acme.app/src"),
        ("/Users/b/Library/Containers/x", "/Users/b/Library/Containers/x"),
    ])
    func projectFoldersLoseTrailingSlashes(path: String, expected: String) {
        #expect(ProjectFolder.directory(for: path, home: "/Users/a") == expected)
    }

    @Test func projectNameFallsBackToProcessName() {
        let launchd = record(.agent, pid: 1, title: "Codex", directory: "/").process
        #expect(launchd.projectDirectory == nil)
        #expect(launchd.projectName == "codex")
        let site = record(.server, pid: 2, title: "Vite", directory: "/tmp/dev/site/").process
        #expect(site.projectDirectory == "/tmp/dev/site")
        #expect(site.projectName == "site")
    }

    @Test func hostApplicationIsTheOutermostAppBundle() {
        func host(_ executable: String) -> String? {
            ProcessRecord(identity: .init(pid: 9, startSeconds: 100), name: "x", executable: executable)
                .hostApplicationName
        }
        #expect(
            host("/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex")
                == "ChatGPT")
        #expect(host("/Applications/Claude.app/Contents/MacOS/Claude") == "Claude")
        #expect(host("/opt/homebrew/bin/codex") == nil)
        // A folder named like an app is no bundle without its Contents.
        #expect(host("/Users/a/dev/site.app/node_modules/.bin/vite") == nil)
    }

    @Test func desktopAppHasNoProject() {
        let process = record(.agent, pid: 1, title: "Codex", directory: "/tmp/project").process
        #expect(ServiceRecord(process: process, kind: .agent, framework: "Codex").projectDirectory == "/tmp/project")
        let app = ServiceRecord(process: process, kind: .agent, framework: "Codex", isDesktopApplication: true)
        #expect(app.projectDirectory == nil)
    }

    @Test func displayOrderRanksKindThenProjectThenNamesThenPID() {
        let services = [
            record(.listener, pid: 1, title: "postgres", directory: "/tmp/a"),
            record(.server, pid: 2, title: "Astro", directory: "/"),
            record(.server, pid: 3, title: "Vite", directory: "/tmp/shop"),
            record(.server, pid: 4, title: "Astro", directory: "/tmp/shop"),
            record(.server, pid: 5, title: "Vite", directory: "/tmp/site10"),
            record(.server, pid: 6, title: "Vite", directory: "/tmp/site2"),
            record(.agent, pid: 7, title: "Codex", directory: "/"),
            record(.agent, pid: 8, title: "Claude", directory: "/tmp/zoo"),
            record(.server, pid: 10, title: "Vite", directory: "/tmp/shop"),
        ]
        let expected: [Int32] = [8, 7, 4, 3, 10, 6, 5, 2, 1]
        #expect(services.sorted(by: ServiceRecord.displayOrder).map(\.id.pid) == expected)
        #expect(services.reversed().sorted(by: ServiceRecord.displayOrder).map(\.id.pid) == expected)
    }

    @Test func loopbackDuplicatesCollapseToOnePort() throws {
        let dual = ports([("::1", 3000), ("127.0.0.1", 3000)])
        #expect(dual.map(\.port) == [3000])
        #expect(dual.first?.primary.address == "127.0.0.1")
        #expect(dual.first?.isNetworkExposed == false)
        let wildcard = try #require(ports([("::1", 3000), ("*", 3000), ("127.0.0.1", 3000)]).first)
        #expect(wildcard.primary.address == "127.0.0.1")
        #expect(wildcard.addresses == ["127.0.0.1", "*", "::1"])
    }

    @Test func addressesFollowPreferenceThenAddress() throws {
        let sockets = ["::", "10.0.0.2", "::1", "localhost", "0.0.0.0", "*", "127.0.0.1", "192.168.1.5"]
        let port = try #require(ports(sockets.map { ($0, 3000) }).first)
        #expect(port.addresses == ["127.0.0.1", "*", "0.0.0.0", "localhost", "::1", "::", "10.0.0.2", "192.168.1.5"])
    }

    @Test func wildcardAloneIsPrimaryAndOpensViaLoopback() throws {
        let port = try #require(ports([("*", 3000)]).first)
        #expect(port.primary.address == "*")
        #expect(port.primary.url?.absoluteString == "http://127.0.0.1:3000")
    }

    @Test func ipv6LoopbackAloneKeepsItsAddress() {
        #expect(ports([("::1", 3000)]).first?.primary.url?.absoluteString == "http://[::1]:3000")
    }

    @Test func lanAddressMarksThePortNetworkExposed() throws {
        let port = try #require(ports([("192.168.1.20", 3000), ("127.0.0.1", 3000)]).first)
        #expect(port.isNetworkExposed)
        #expect(port.primary.address == "127.0.0.1")
    }

    @Test func portsSortAscendingAndThePrimaryEndpointIsTheLowestPort() {
        let endpoints = [("*", 8080), ("::1", 3000), ("127.0.0.1", 5173), ("127.0.0.1", 3000)].map {
            ListeningEndpoint(pid: 1, address: $0.0, port: UInt16($0.1))
        }
        let service = record(.server, pid: 1, title: "Vite", directory: "/tmp/site", endpoints: endpoints)
        #expect(service.ports.map(\.id) == [3000, 5173, 8080])
        #expect(service.primaryEndpoint == ListeningEndpoint(pid: 1, address: "127.0.0.1", port: 3000))
        #expect(service.endpoints == endpoints)
        #expect(record(.agent, pid: 2, title: "Codex", directory: nil).primaryEndpoint == nil)
    }
}
