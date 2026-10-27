import Darwin
import Foundation
import Synchronization
import Testing

@testable import PortsCore

/// A loopback server on an ephemeral port that answers each connection the way its mode says, on a thread of its own,
/// so the probe talks to real sockets.
private final class LoopbackFixture: Sendable {
    enum Mode: Sendable {
        /// Reads the request and answers 404 with an empty body.
        case http404
        /// Reads the request and closes without answering.
        case closeAfterRead
        /// Reads the request and answers with this text, the way Redis rejects an unknown command.
        case reply(String)
        /// Greets before reading, the way SSH and SMTP servers do.
        case greetFirst
        /// Accepts and keeps the connection open without writing.
        case silent
    }

    let port: UInt16
    let origin: URL
    private let state = Mutex((accepted: 0, requests: [String](), isStopped: false))

    init(_ address: String = "127.0.0.1", mode: Mode) throws {
        let listener = try bindListener(address, v6only: address.contains(":"))
        port = listener.port
        origin = try #require(ListeningEndpoint(pid: getpid(), address: address, port: listener.port).url)
        Thread.detachNewThread { [self] in serve(listener.descriptor, mode: mode) }
    }

    var accepted: Int { state.withLock { $0.accepted } }
    var requests: [String] { state.withLock { $0.requests } }

    /// The serving thread notices within one poll interval and closes every socket.
    func stop() { state.withLock { $0.isStopped = true } }

    private func serve(_ listener: Int32, mode: Mode) {
        var held: [Int32] = []
        var readable = pollfd(fd: listener, events: Int16(POLLIN), revents: 0)
        while !state.withLock({ $0.isStopped }) {
            guard poll(&readable, 1, 20) > 0 else { continue }
            let client = accept(listener, nil, nil)
            guard client >= 0 else { continue }
            state.withLock { $0.accepted += 1 }
            // A probe that already hung up must not end the test process with SIGPIPE.
            var enabled: Int32 = 1
            setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size))
            if case .silent = mode {
                held.append(client)
                continue
            }
            if case .greetFirst = mode { Self.write("SSH-2.0-OpenSSH_9.9\r\n", to: client) }
            let request = Self.readRequest(client)
            state.withLock { $0.requests.append(request) }
            switch mode {
            case .http404:
                Self.write("HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n", to: client)
            case .reply(let text): Self.write(text, to: client)
            case .closeAfterRead, .greetFirst, .silent: break
            }
            close(client)
        }
        for client in held { close(client) }
        close(listener)
    }

    /// Reads until the blank line that ends the request head, the peer closes, or two seconds pass. Reading all of it
    /// lets the close send a FIN rather than a reset.
    private static func readRequest(_ client: Int32) -> String {
        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var received: [UInt8] = []
        var buffer = [UInt8](repeating: 0, count: 1024)
        while !String(decoding: received, as: UTF8.self).contains("\r\n\r\n") {
            let count = recv(client, &buffer, buffer.count, 0)
            guard count > 0 else { break }
            received += buffer.prefix(count)
        }
        return String(decoding: received, as: UTF8.self)
    }

    private static func write(_ text: String, to client: Int32) {
        let bytes = Array(text.utf8)
        _ = bytes.withUnsafeBytes { Darwin.write(client, $0.baseAddress, $0.count) }
    }
}

struct HTTPOriginProbeTests {
    private let probe = HTTPOriginProbe()

    @Test func httpIncluding404IsHTTP() async throws {
        let fixture = try LoopbackFixture(mode: .http404)
        defer { fixture.stop() }
        #expect(await probe.verdict(for: fixture.origin) == .http)
        let request = "HEAD / HTTP/1.1\r\nHost: 127.0.0.1:\(fixture.port)\r\nAccept: */*\r\nConnection: close\r\n\r\n"
        #expect(fixture.requests == [request])
    }

    @Test func ipv6LoopbackHTTP() async throws {
        let fixture = try LoopbackFixture("::1", mode: .http404)
        defer { fixture.stop() }
        #expect(fixture.origin.absoluteString == "http://[::1]:\(fixture.port)")
        #expect(await probe.verdict(for: fixture.origin) == .http)
        #expect(fixture.requests.first?.contains("\r\nHost: [::1]:\(fixture.port)\r\n") == true)
    }

    @Test func closeAfterReadIsNotHTTP() async throws {
        let fixture = try LoopbackFixture(mode: .closeAfterRead)
        defer { fixture.stop() }
        #expect(await probe.verdict(for: fixture.origin) == .notHTTP)
    }

    @Test func protocolErrorReplyIsNotHTTP() async throws {
        let fixture = try LoopbackFixture(mode: .reply("-ERR unknown command 'HEAD'\r\n"))
        defer { fixture.stop() }
        #expect(await probe.verdict(for: fixture.origin) == .notHTTP)
    }

    @Test func serverFirstGreetingIsNotHTTP() async throws {
        let fixture = try LoopbackFixture(mode: .greetFirst)
        defer { fixture.stop() }
        #expect(await probe.verdict(for: fixture.origin) == .notHTTP)
    }

    @Test func silentServerIsInconclusive() async throws {
        let fixture = try LoopbackFixture(mode: .silent)
        defer { fixture.stop() }
        let clock = ContinuousClock()
        let start = clock.now
        #expect(await HTTPOriginProbe(timeout: .milliseconds(200)).verdict(for: fixture.origin) == .inconclusive)
        #expect(clock.now - start < .seconds(1))
        #expect(fixture.accepted == 1)
    }

    @Test func cancellationIsInconclusive() async throws {
        let fixture = try LoopbackFixture(mode: .silent)
        defer { fixture.stop() }
        let probe = HTTPOriginProbe(timeout: .seconds(30))
        let origin = fixture.origin
        // Cancelled before the probe starts: it never connects.
        let early = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await probe.verdict(for: origin)
        }
        #expect(await early.value == .inconclusive)
        #expect(fixture.accepted == 0)
        // Cancelled while the connection waits for an answer.
        let clock = ContinuousClock()
        let start = clock.now
        let waiting = Task { await probe.verdict(for: origin) }
        while fixture.accepted == 0, clock.now - start < .seconds(1) { try await Task.sleep(for: .milliseconds(10)) }
        waiting.cancel()
        #expect(await waiting.value == .inconclusive)
        #expect(fixture.accepted == 1)
        #expect(clock.now - start < .seconds(1))
    }

    @Test func closedPortIsUnreachable() async throws {
        for address in ["127.0.0.1", "::1"] {
            let listener = try bindListener(address, v6only: address.contains(":"))
            close(listener.descriptor)
            let origin = try #require(ListeningEndpoint(pid: getpid(), address: address, port: listener.port).url)
            #expect(await probe.verdict(for: origin) == .unreachable, "\(address)")
        }
    }

    @Test func nonLoopbackAndHTTPSAreRejectedWithoutConnecting() async throws {
        let fixture = try LoopbackFixture(mode: .http404)
        defer { fixture.stop() }
        let port = fixture.port
        let origins = [
            "https://127.0.0.1:\(port)", "ftp://127.0.0.1:\(port)", "http://localhost:\(port)",
            "http://192.168.1.5:\(port)", "http://10.0.0.2:\(port)", "http://[::ffff:127.0.0.1]:\(port)",
            "http://127.0.0.1", "http://127.0.0.1:0", "http://127.0.0.1:65536",
        ]
        let clock = ContinuousClock()
        let start = clock.now
        for text in origins {
            let origin = try #require(URL(string: text))
            #expect(await probe.verdict(for: origin) == .notHTTP, "\(text)")
        }
        #expect(clock.now - start < .milliseconds(50))
        #expect(fixture.accepted == 0)
    }
}
