import Foundation
import Network

/// What one HEAD request learned about a loopback origin.
public enum HTTPOriginVerdict: Sendable, Equatable {
    /// The reply starts with an HTTP status line. Any status code counts.
    case http
    /// Something else answered, the peer closed without a status line, or the URL isn't a loopback HTTP origin.
    case notHTTP
    /// Nothing listens on the port.
    case unreachable
    /// No answer within the timeout, or the probe was cancelled.
    case inconclusive
}

/// Sharing exposes whatever answers on the port. One HEAD request over loopback confirms it speaks HTTP; slow is
/// inconclusive, never a rejection.
public struct HTTPOriginProbe: Sendable {
    public static let defaultTimeout: Duration = .milliseconds(1500)
    public let timeout: Duration

    public init(timeout: Duration = HTTPOriginProbe.defaultTimeout) {
        self.timeout = timeout
    }

    /// Returns `.notHTTP` without connecting unless the origin is http://127.0.0.1 or http://[::1] with a port. No
    /// retries, redirects or User-Agent.
    public func verdict(for origin: URL) async -> HTTPOriginVerdict {
        // The loopback interface requirement alone still reaches the Mac's LAN address, so the host is checked too.
        let host: NWEndpoint.Host
        let authority: String
        switch origin.host {
        case "127.0.0.1":
            host = .ipv4(.loopback)
            authority = "127.0.0.1"
        case "::1":
            host = .ipv6(.loopback)
            authority = "[::1]"
        default:
            return .notHTTP
        }
        guard origin.scheme == "http", let number = origin.port, (1...65535).contains(number),
            let port = NWEndpoint.Port(rawValue: UInt16(number))
        else { return .notHTTP }
        let parameters = NWParameters.tcp
        parameters.requiredInterfaceType = .loopback
        parameters.preferNoProxies = true
        let request = "HEAD / HTTP/1.1\r\nHost: \(authority):\(number)\r\nAccept: */*\r\nConnection: close\r\n\r\n"
        // The classic NWConnection, because the macOS 26 NetworkConnection API hides ECONNREFUSED.
        let outcome = ProbeOutcome(NWConnection(host: host, port: port, using: parameters), request: Data(request.utf8))
        return await withTaskCancellationHandler {
            await withCheckedContinuation { outcome.start(timeout: timeout, continuation: $0) }
        } onCancel: {
            outcome.finish(.inconclusive)
        }
    }
}

/// One probe's connection and result. The first verdict wins: it resumes the waiting task once and cancels the
/// connection, so later callbacks, the timeout and cancellation find the probe finished.
private final class ProbeOutcome: @unchecked Sendable {
    private static let statusLinePrefix = Data("HTTP/".utf8)
    private let connection: NWConnection
    private let request: Data
    private let lock = NSLock()
    // Guarded by `lock`.
    private var continuation: CheckedContinuation<HTTPOriginVerdict, Never>?
    private var verdict: HTTPOriginVerdict?

    init(_ connection: NWConnection, request: Data) {
        self.connection = connection
        self.request = request
        // Weak, so a connection that never starts doesn't keep itself alive through its own handler.
        connection.stateUpdateHandler = { [weak self] state in self?.handle(state) }
    }

    /// Starts the connection on a private serial queue, unless the task was cancelled before it got here.
    func start(timeout: Duration, continuation: CheckedContinuation<HTTPOriginVerdict, Never>) {
        lock.withLock {
            if let verdict { return continuation.resume(returning: verdict) }
            self.continuation = continuation
            let queue = DispatchQueue(label: "de.byte.ports.http-probe")
            connection.start(queue: queue)
            let (seconds, attoseconds) = timeout.components
            let nanoseconds = Int(seconds) * 1_000_000_000 + Int(attoseconds / 1_000_000_000)
            queue.asyncAfter(deadline: .now() + .nanoseconds(nanoseconds)) { [weak self] in
                self?.finish(.inconclusive)
            }
        }
    }

    func finish(_ verdict: HTTPOriginVerdict) {
        lock.withLock {
            guard self.verdict == nil else { return }
            self.verdict = verdict
            // Not started yet: `start` resumes with the stored verdict.
            guard let continuation else { return }
            self.continuation = nil
            connection.cancel()
            continuation.resume(returning: verdict)
        }
    }

    private func handle(_ state: NWConnection.State) {
        switch state {
        case .ready:
            connection.send(content: request, completion: .idempotent)
            let length = Self.statusLinePrefix.count
            connection.receive(minimumIncompleteLength: length, maximumLength: length) { [weak self] data, _, _, _ in
                self?.finish(data == Self.statusLinePrefix ? .http : .notHTTP)
            }
        case .waiting(let error), .failed(let error):
            // Refused means nothing listens; any other failure is no HTTP answer either.
            if case .posix(.ECONNREFUSED) = error {
                finish(.unreachable)
            } else {
                finish(.notHTTP)
            }
        default:
            break
        }
    }
}
