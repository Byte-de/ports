import Foundation
import Testing

@testable import PortsCore

struct LaunchConfigurationTests {
    private let web = LaunchConfiguration(name: "Web", command: "npm run dev", directory: "/tmp")
    private let api = LaunchConfiguration(name: "API", command: "npm run api", directory: "/tmp")
    private let docs = LaunchConfiguration(name: " Docs\n", command: "npm run docs", directory: "/tmp")

    @Test func nameTakenIgnoresCaseWidthAndWhitespace() {
        let saved = [web, api, docs]
        #expect(LaunchConfiguration.isNameTaken("web", excluding: nil, in: saved))
        #expect(LaunchConfiguration.isNameTaken("  WEB\t", excluding: nil, in: saved))
        // Full-width letters, as East Asian input methods type them.
        #expect(LaunchConfiguration.isNameTaken("ａｐｉ", excluding: nil, in: saved))
        // A saved name with stray whitespace still counts.
        #expect(LaunchConfiguration.isNameTaken("docs", excluding: nil, in: saved))
        #expect(!LaunchConfiguration.isNameTaken("Web 2", excluding: nil, in: saved))
        #expect(!LaunchConfiguration.isNameTaken("Web", excluding: nil, in: []))
    }

    @Test func nameTakenExcludesItself() {
        let saved = [web, api]
        #expect(!LaunchConfiguration.isNameTaken("WEB ", excluding: web.id, in: saved))
        #expect(LaunchConfiguration.isNameTaken("api", excluding: web.id, in: saved))
        // A new action has an id no saved action has.
        #expect(LaunchConfiguration.isNameTaken("Web", excluding: UUID(), in: saved))
    }
}
