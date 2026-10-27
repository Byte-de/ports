import Darwin
import Foundation
import Testing

@testable import PortsCore

/// Listens on an ephemeral port in the test process. A ':' in the address selects IPv6. The caller closes the
/// descriptor.
func bindListener(_ address: String, v6only: Bool = false) throws -> (descriptor: Int32, port: UInt16) {
    let ipv6 = address.contains(":")
    let descriptor = socket(ipv6 ? AF_INET6 : AF_INET, SOCK_STREAM, 0)
    try #require(descriptor >= 0)
    do {
        if ipv6 {
            var flag: Int32 = v6only ? 1 : 0
            let size = socklen_t(MemoryLayout<Int32>.size)
            try #require(setsockopt(descriptor, IPPROTO_IPV6, IPV6_V6ONLY, &flag, size) == 0)
            var socketAddress = sockaddr_in6()
            socketAddress.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
            socketAddress.sin6_family = sa_family_t(AF_INET6)
            try #require(inet_pton(AF_INET6, address, &socketAddress.sin6_addr) == 1)
            try bindAndListen(descriptor, &socketAddress)
            return (descriptor, UInt16(bigEndian: socketAddress.sin6_port))
        }
        var socketAddress = sockaddr_in()
        socketAddress.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        socketAddress.sin_family = sa_family_t(AF_INET)
        try #require(inet_pton(AF_INET, address, &socketAddress.sin_addr) == 1)
        try bindAndListen(descriptor, &socketAddress)
        return (descriptor, UInt16(bigEndian: socketAddress.sin_port))
    } catch {
        close(descriptor)
        throw error
    }
}

/// Binds to port 0 and reads the port the system assigned back into the address.
private func bindAndListen<Address>(_ descriptor: Int32, _ address: inout Address) throws {
    var length = socklen_t(MemoryLayout<Address>.size)
    try withUnsafeMutablePointer(to: &address) { pointer in
        try pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
            try #require(bind(descriptor, socketAddress, length) == 0)
            try #require(listen(descriptor, 4) == 0)
            try #require(getsockname(descriptor, socketAddress, &length) == 0)
        }
    }
}

struct NativeListenerTests {
    private let discovery = NativeListenerDiscovery()

    @Test func findsLoopbackListenersOfOwnProcess() throws {
        let ipv4 = try bindListener("127.0.0.1")
        defer { close(ipv4.descriptor) }
        let ipv6 = try bindListener("::1", v6only: true)
        defer { close(ipv6.descriptor) }
        let mapped = try bindListener("::ffff:127.0.0.1")
        defer { close(mapped.descriptor) }
        let pid = getpid()
        let expected: Set<ListeningEndpoint> = [
            .init(pid: pid, address: "127.0.0.1", port: ipv4.port),
            .init(pid: pid, address: "::1", port: ipv6.port),
            .init(pid: pid, address: "127.0.0.1", port: mapped.port),
        ]
        #expect(expected.isSubset(of: try #require(discovery.listeners(of: pid))))
        // A missing process is skipped as long as another one could be read.
        #expect(expected.isSubset(of: try discovery.listeners(of: [999_999, pid])))
    }

    @Test func closedListenerDisappears() throws {
        let listener = try bindListener("127.0.0.1")
        var isOpen = true
        defer { if isOpen { close(listener.descriptor) } }
        #expect(discovery.listeners(of: getpid())?.contains { $0.port == listener.port } == true)
        close(listener.descriptor)
        isOpen = false
        #expect(discovery.listeners(of: getpid())?.contains { $0.port == listener.port } == false)
    }

    @Test func foreignAndMissingProcessesAreNotInspectable() throws {
        #expect(discovery.listeners(of: 1) == nil)
        #expect(discovery.listeners(of: 999_999) == nil)
        #expect(throws: MonitorError.self) { try discovery.listeners(of: [1, 999_999]) }
        #expect(try discovery.listeners(of: []).isEmpty)
    }

    @Test(
        .enabled(
            if: ProcessInfo.processInfo.environment["CI"] != nil,
            "Wildcard binds can trigger the application firewall prompt on developer Macs"))
    func mapsWildcardFamilies() throws {
        let ipv4 = try bindListener("0.0.0.0")
        defer { close(ipv4.descriptor) }
        let dualStack = try bindListener("::")
        defer { close(dualStack.descriptor) }
        let ipv6Only = try bindListener("::", v6only: true)
        defer { close(ipv6Only.descriptor) }
        let endpoints = try #require(discovery.listeners(of: getpid()))
        let addresses = [ipv4.port, dualStack.port, ipv6Only.port].map { port in
            endpoints.first { $0.port == port }?.address
        }
        #expect(addresses == ["*", "*", "::"])
    }
}
