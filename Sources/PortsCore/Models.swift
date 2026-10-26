import Foundation

/// PID alone is not an identity: macOS reuses it after a process exits.
public struct ProcessIdentity: Hashable, Codable, Sendable {
    public let pid: Int32
    public let startSeconds: UInt64
    public let startMicroseconds: UInt64

    public init(pid: Int32, startSeconds: UInt64, startMicroseconds: UInt64 = 0) {
        self.pid = pid
        self.startSeconds = startSeconds
        self.startMicroseconds = startMicroseconds
    }

    public var startDate: Date {
        Date(timeIntervalSince1970: Double(startSeconds) + Double(startMicroseconds) / 1_000_000)
    }
}

public enum ProcessState: String, Codable, Sendable {
    case running, paused, exited
}

public struct ProcessRecord: Sendable, Equatable {
    public let identity: ProcessIdentity
    public let parentPID: Int32
    public let userID: UInt32
    public let name: String
    public let executable: String
    public let arguments: [String]
    public let workingDirectory: String?
    public let state: ProcessState
    public let residentBytes: UInt64?
    public let cpuNanoseconds: UInt64?

    public init(
        identity: ProcessIdentity, parentPID: Int32 = 1, userID: UInt32 = 501,
        name: String, executable: String, arguments: [String] = [],
        workingDirectory: String? = nil, state: ProcessState = .running,
        residentBytes: UInt64? = nil, cpuNanoseconds: UInt64? = nil
    ) {
        self.identity = identity
        self.parentPID = parentPID
        self.userID = userID
        self.name = name
        self.executable = executable
        self.arguments = arguments
        self.workingDirectory = workingDirectory
        self.state = state
        self.residentBytes = residentBytes
        self.cpuNanoseconds = cpuNanoseconds
    }

    public var command: String {
        (arguments.isEmpty ? [executable] : arguments).map(ShellEscaping.quote).joined(separator: " ")
    }

    public var projectName: String {
        guard let directory = workingDirectory, directory != "/" else { return name }
        return URL(fileURLWithPath: directory).lastPathComponent
    }
}

public struct ListeningEndpoint: Hashable, Codable, Sendable {
    public let pid: Int32
    public let address: String
    public let port: UInt16

    public init(pid: Int32, address: String, port: UInt16) {
        self.pid = pid
        self.address = address
        self.port = port
    }

    public var isNetworkExposed: Bool {
        !["127.0.0.1", "::1", "localhost"].contains(address)
    }

    /// Wildcard binds are opened via loopback. A specific interface keeps its address.
    public var url: URL? {
        var components = URLComponents()
        components.scheme = "http"
        components.host =
            ["*", "0.0.0.0", "127.0.0.1"].contains(address)
            ? "127.0.0.1"
            : (["::", "::1"].contains(address) ? "[::1]" : (address.contains(":") ? "[\(address)]" : address))
        components.port = Int(port)
        return components.url
    }
}

public enum ServiceKind: String, CaseIterable, Codable, Sendable {
    case agent, server, listener
}

public struct AgentProvider: Hashable, Codable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public let symbol: String

    public init(id: String, name: String, symbol: String = "sparkles") {
        self.id = id
        self.name = name
        self.symbol = symbol
    }
}

public struct ServiceRecord: Identifiable, Equatable, Sendable {
    public var id: ProcessIdentity { process.identity }
    public let process: ProcessRecord
    public let kind: ServiceKind
    public let provider: AgentProvider?
    public let framework: String
    public let endpoints: [ListeningEndpoint]
    public let cpuPercent: Double?
    public let isDesktopApplication: Bool

    public init(
        process: ProcessRecord, kind: ServiceKind, provider: AgentProvider? = nil,
        framework: String, endpoints: [ListeningEndpoint] = [], cpuPercent: Double? = nil,
        isDesktopApplication: Bool = false
    ) {
        self.process = process
        self.kind = kind
        self.provider = provider
        self.framework = framework
        self.endpoints = endpoints
        self.cpuPercent = cpuPercent
        self.isDesktopApplication = isDesktopApplication
    }

    public var title: String { provider?.name ?? framework }
    public var primaryEndpoint: ListeningEndpoint? { endpoints.first }
    public var projectKey: String { process.workingDirectory ?? process.executable }
}

public struct ScanSnapshot: Sendable {
    public let services: [ServiceRecord]
    public let scannedAt: Date
    public let processCount: Int
    public let warning: String?

    public init(services: [ServiceRecord], scannedAt: Date = Date(), processCount: Int, warning: String? = nil) {
        self.services = services
        self.scannedAt = scannedAt
        self.processCount = processCount
        self.warning = warning
    }
}

public enum ShellEscaping {
    public static func quote(_ value: String) -> String {
        guard !value.isEmpty else { return "''" }
        let safe = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_./:=+-@")
        if value.unicodeScalars.allSatisfy(safe.contains) { return value }
        return "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
