import Foundation
import Testing

@testable import PortsCore

struct ListenerParserTests {
    @Test func parsesIPv4IPv6AndWildcardWithoutDuplicates() {
        let input = "p42\ncnode server\nf10\nn127.0.0.1:3000\nn127.0.0.1:3000\nn[::1]:5173\np43\nn*:8080\n"
        let endpoints = ListenerParser.parse(input)
        #expect(endpoints.count == 3)
        #expect(endpoints.contains(.init(pid: 42, address: "::1", port: 5173)))
        #expect(endpoints.contains(.init(pid: 43, address: "*", port: 8080)))
    }

    @Test func ignoresInvalidPortsAndOrphanedNames() {
        let input = "n127.0.0.1:3000\npbad\nn*:8080\np12\nn*:0\nn*:65536\nn*:abc\nn:80\nn*:443\n"
        #expect(ListenerParser.parse(input) == [.init(pid: 12, address: "*", port: 443)])
    }

    @Test(arguments: [
        ("127.0.0.1", "http://127.0.0.1:3000", false),
        ("*", "http://127.0.0.1:3000", true),
        ("0.0.0.0", "http://127.0.0.1:3000", true),
        ("::1", "http://[::1]:3000", false),
        ("::", "http://[::1]:3000", true),
        ("192.168.1.7", "http://192.168.1.7:3000", true),
    ])
    func generatesReachableURL(address: String, expected: String, exposed: Bool) {
        let endpoint = ListeningEndpoint(pid: 10, address: address, port: 3000)
        #expect(endpoint.url?.absoluteString == expected)
        #expect(endpoint.isNetworkExposed == exposed)
    }
}
