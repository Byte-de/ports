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
    // Derived once in init: every scan sort and every row render reads both.
    public let projectDirectory: String?
    /// The project folder's name, else the process name.
    public let projectName: String

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
        let projectDirectory = ProjectFolder.directory(for: workingDirectory)
        self.projectDirectory = projectDirectory
        self.projectName = projectDirectory.map { URL(fileURLWithPath: $0).lastPathComponent } ?? name
    }

    public var command: String {
        (arguments.isEmpty ? [executable] : arguments).map(ShellEscaping.quote).joined(separator: " ")
    }
}

/// A working directory names a project only when a person chose it: launchd starts apps in '/', helpers run inside
/// their bundle, and app data lives in Library. Cloud and iCloud Drive folders in Library hold real projects.
public enum ProjectFolder {
    public static let home = NSHomeDirectory()
    private static let homeData = [
        "Application Support", "Containers", "Group Containers", "Caches", "Preferences", "Saved Application State",
        "Developer/Xcode/DerivedData",
    ]
    private static let systemData = ["Application Support", "Apple", "Caches"]
    /// Every scanned process runs through `directory(for:)`, so the real home's prefixes are split only once.
    private static let defaultDataPrefixes = dataPrefixes(home: home)

    /// nil when `path` is no project folder, otherwise `path` without trailing slashes. The home folder is a project.
    public static func directory(for path: String?, home: String = ProjectFolder.home) -> String? {
        guard var path else { return nil }
        while path.hasSuffix("/") { path.removeLast() }
        let components = lowercasedComponents(of: path)
        let prefixes = home == Self.home ? defaultDataPrefixes : dataPrefixes(home: home)
        let isAppData = prefixes.contains { components.starts(with: $0) }
        let isInBundle = zip(components, components.dropFirst()).contains { $0.hasSuffix(".app") && $1 == "contents" }
        return components.isEmpty || isAppData || isInBundle ? nil : path
    }

    private static func dataPrefixes(home: String) -> [[Substring]] {
        (homeData.map { "\(home)/Library/\($0)" } + systemData.map { "/Library/\($0)" }).map(lowercasedComponents)
    }

    /// Components compare case-insensitively, as APFS does by default. Splitting the UTF-8 bytes skips the grapheme
    /// breaking that makes `String.split` several times slower.
    private static func lowercasedComponents(of path: String) -> [Substring] {
        path.lowercased().utf8.split(separator: UInt8(ascii: "/")).map(Substring.init)
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

    /// The origin URL for '*' is also 127.0.0.1, so the loopback socket the URL names comes first.
    var preference: Int {
        switch address {
        case "127.0.0.1": 0
        case "*", "0.0.0.0": 1
        case "localhost": 2
        case "::1": 3
        case "::": 4
        default: 5
        }
    }
}

/// 127.0.0.1, ::1 and * on one port are one server: one address row, one share.
public struct ServicePort: Hashable, Sendable, Identifiable {
    public let port: UInt16
    /// Preferred first and never empty.
    public let endpoints: [ListeningEndpoint]

    public var id: UInt16 { port }
    public var primary: ListeningEndpoint { endpoints[0] }
    public var addresses: [String] { endpoints.map(\.address) }
    public var isNetworkExposed: Bool { endpoints.contains(where: \.isNetworkExposed) }

    private init(port: UInt16, endpoints: [ListeningEndpoint]) {
        self.port = port
        self.endpoints = endpoints.sorted { ($0.preference, $0.address) < ($1.preference, $1.address) }
    }

    /// One entry per port, by port ascending.
    public static func group(_ endpoints: [ListeningEndpoint]) -> [ServicePort] {
        Dictionary(grouping: endpoints, by: \.port).sorted { $0.key < $1.key }.map {
            ServicePort(port: $0.key, endpoints: $0.value)
        }
    }
}

public enum ServiceKind: String, CaseIterable, Codable, Sendable {
    case agent, server, listener

    /// Lists show agents first and other TCP listeners last.
    public var sortRank: Int {
        switch self {
        case .agent: 0
        case .server: 1
        case .listener: 2
        }
    }
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
    /// Every socket, for validation and search. Views show `ports`.
    public let endpoints: [ListeningEndpoint]
    /// Grouped once in init: every row render reads the primary endpoint.
    public let ports: [ServicePort]
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
        self.ports = ServicePort.group(endpoints)
        self.cpuPercent = cpuPercent
        self.isDesktopApplication = isDesktopApplication
    }

    public var title: String { provider?.name ?? framework }
    public var primaryEndpoint: ListeningEndpoint? { ports.first?.primary }
    /// A desktop app's working directory is chosen by launchd, not by a person.
    public var projectDirectory: String? { isDesktopApplication ? nil : process.projectDirectory }

    /// Kind, then services with a project, then project name, title and PID.
    public static func displayOrder(_ lhs: ServiceRecord, _ rhs: ServiceRecord) -> Bool {
        if lhs.kind.sortRank != rhs.kind.sortRank { return lhs.kind.sortRank < rhs.kind.sortRank }
        if (lhs.projectDirectory == nil) != (rhs.projectDirectory == nil) { return lhs.projectDirectory != nil }
        for (left, right) in [(lhs.process.projectName, rhs.process.projectName), (lhs.title, rhs.title)] {
            let order = left.localizedStandardCompare(right)
            if order != .orderedSame { return order == .orderedAscending }
        }
        return lhs.id.pid < rhs.id.pid
    }
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
