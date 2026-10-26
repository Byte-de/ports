import Darwin
import Foundation

public struct TunnelKey: Hashable, Sendable {
    public let process: ProcessIdentity
    public let origin: URL
}

public struct TunnelTarget: Identifiable, Equatable, Sendable {
    public let id: TunnelKey
    public let endpoint: ListeningEndpoint
    public let name: String

    public init(service: ServiceRecord, endpoint: ListeningEndpoint) throws {
        var ipv4 = in_addr()
        var ipv6 = in6_addr()
        let localAddress =
            ["*", "localhost"].contains(endpoint.address)
            || inet_pton(AF_INET, endpoint.address, &ipv4) == 1
            || inet_pton(AF_INET6, endpoint.address, &ipv6) == 1
        guard service.kind == .server, !service.isDesktopApplication,
            service.process.state == .running, endpoint.pid == service.id.pid,
            service.endpoints.contains(endpoint), endpoint.port > 0, localAddress,
            let origin = endpoint.url, origin.scheme == "http", origin.host != nil
        else { throw TunnelError.unsupportedServer }
        id = TunnelKey(process: service.id, origin: origin)
        self.endpoint = endpoint
        name = service.process.projectName
    }
}

public enum TunnelPhase: Equatable, Sendable {
    case starting, ready, reconnecting, stopping, stopped, failed
    public var isActive: Bool { [.starting, .ready, .reconnecting, .stopping].contains(self) }
}

public struct TunnelRecord: Identifiable, Equatable, Sendable {
    public var id: TunnelKey { target.id }
    public let target: TunnelTarget
    public let sessionID: UUID
    public var phase: TunnelPhase
    public var publicURL: URL?
    public var message: String?
}

public enum TunnelError: LocalizedError, Sendable {
    case unsupportedServer, unsupportedSystem, serverChanged, missingClient, shuttingDown, couldNotStop
    public var errorDescription: String? {
        switch self {
        case .unsupportedServer:
            String(
                localized: "Only running local HTTP development servers can be shared.",
                comment: "Error when public sharing is requested for anything but a running local HTTP server")
        case .unsupportedSystem:
            String(
                localized: "Public sharing requires macOS 15 or later.",
                comment: "Error when public sharing is requested on a macOS version that cannot run it")
        case .serverChanged:
            String(
                localized: "The server or its port is no longer active. Please try again.",
                comment: "Error when the server to share stopped or changed before sharing started")
        case .missingClient:
            String(
                localized:
                    "The Cloudflare client is missing from this installation. Please download and reinstall the app.",
                comment: "Error when the bundled Cloudflare client or its launcher is missing or not executable")
        case .shuttingDown:
            String(localized: "The app is quitting.", comment: "Error when sharing is started while the app quits")
        case .couldNotStop:
            String(
                localized: "Sharing has not stopped yet. Please stop it again.",
                comment: "Error when a public share did not end in time after Stop sharing")
        }
    }
}

/// cloudflared is launched with --output json. Its URL banner can precede a
/// usable edge connection; a URL alone must never be presented as ready.
struct CloudflareLogState: Sendable {
    private(set) var publicURL: URL?
    private(set) var connected = false
    private(set) var wasConnected = false
    private(set) var lastError: String?
    private var partial = Data()
    private var discardingLine = false
    static let maximumLineBytes = 65_536

    mutating func append(_ data: Data) {
        for byte in data {
            if byte == 10 {
                if !discardingLine { consume(String(decoding: partial, as: UTF8.self)) }
                partial.removeAll(keepingCapacity: true)
                discardingLine = false
            } else if !discardingLine {
                if partial.count < Self.maximumLineBytes {
                    partial.append(byte)
                } else {
                    partial.removeAll(keepingCapacity: true)
                    discardingLine = true
                }
            }
        }
    }

    private mutating func consume(_ line: String) {
        let object = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any]
        let message = object?["message"] as? String ?? line
        if publicURL == nil {
            publicURL =
                message.split(whereSeparator: { $0.isWhitespace || $0 == "|" })
                .compactMap { Self.validatedURL(String($0)) }.first
        }
        if message.hasPrefix("Registered tunnel connection") {
            connected = true
            wasConnected = true
        } else if message.hasPrefix("Unregistered tunnel connection")
            || message.hasPrefix("Connection terminated") || message.hasPrefix("Retrying connection")
        {
            connected = false
        }
        if object?["level"] as? String == "error" {
            let detail = object?["error"] as? String
            lastError = String((detail ?? message).prefix(300))
        }
    }

    static func validatedURL(_ text: String) -> URL? {
        guard let url = URL(string: text), let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
            parts.scheme == "https", parts.user == nil, parts.password == nil, parts.port == nil,
            parts.query == nil, parts.fragment == nil, parts.path.isEmpty || parts.path == "/",
            let host = parts.host,
            host.range(
                of: #"^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.trycloudflare\.com$"#,
                options: .regularExpression) != nil
        else { return nil }
        return url
    }
}

/// Bounded synchronous parsing prevents noisy child output from queuing Tasks.
final class CloudflareLogBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var state = CloudflareLogState()
    func append(_ data: Data) {
        lock.lock()
        defer { lock.unlock() }
        state.append(data)
    }
    func snapshot() -> CloudflareLogState {
        lock.lock()
        defer { lock.unlock() }
        return state
    }
}

struct TunnelOriginValidator: Sendable {
    func isCurrent(_ target: TunnelTarget) -> Bool {
        let inspector = NativeProcessInspector()
        guard inspector.process(pid: target.id.process.pid)?.identity == target.id.process,
            let result = try? CommandRunner().run(
                executable: "/usr/sbin/lsof",
                arguments: ["-nP", "-a", "-p", String(target.id.process.pid), "-iTCP", "-sTCP:LISTEN", "-Fpn"],
                timeout: 2, outputLimit: 262_144),
            ListenerParser.parse(result.output).contains(target.endpoint),
            inspector.process(pid: target.id.process.pid)?.identity == target.id.process
        else { return false }
        return true
    }
}
