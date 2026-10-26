import Darwin
import Foundation

public protocol ListenerDiscovering: Sendable {
    func listeners() throws -> [ListeningEndpoint]
}

public struct LsofListenerDiscovery: ListenerDiscovering {
    public init() {}
    public func listeners() throws -> [ListeningEndpoint] {
        let result = try CommandRunner().run(
            executable: "/usr/sbin/lsof",
            arguments: [
                "-nP", "-a", "-u", String(getuid()), "-iTCP", "-sTCP:LISTEN", "-Fpn",
            ])
        // lsof uses 1 for a successful search without matching listeners.
        guard result.exitCode == 0 || (result.exitCode == 1 && result.output.isEmpty) else {
            throw MonitorError.scanFailed("Die TCP-Listener konnten nicht abgefragt werden.")
        }
        return ListenerParser.parse(result.output)
    }
}

public actor ProcessScanner {
    private struct Sample: Sendable {
        let cpu: UInt64
        let time: TimeInterval
    }
    private let inspector: any ProcessInspecting
    private let listenerDiscovery: any ListenerDiscovering
    private var samples: [ProcessIdentity: Sample] = [:]

    public init(
        inspector: any ProcessInspecting = NativeProcessInspector(),
        listenerDiscovery: any ListenerDiscovering = LsofListenerDiscovery()
    ) {
        self.inspector = inspector
        self.listenerDiscovery = listenerDiscovery
    }

    public func scan(customRules: [AgentRule] = []) throws -> ScanSnapshot {
        let records = try inspector.processes().filter { $0.state != .exited }
        let processMap = Dictionary(records.map { ($0.identity.pid, $0) }, uniquingKeysWith: { first, _ in first })
        var warning: String?
        var listeners: [ListeningEndpoint] = []
        do {
            listeners = try listenerDiscovery.listeners()
        } catch {
            warning = error.localizedDescription
        }
        let grouped = Dictionary(grouping: listeners, by: \.pid)
        let classifier = ServiceClassifier(customRules: customRules)
        let now = ProcessInfo.processInfo.systemUptime
        var nextSamples: [ProcessIdentity: Sample] = [:]
        var services: [ServiceRecord] = []
        for var process in records {
            var endpoints = grouped[process.identity.pid] ?? []
            if !endpoints.isEmpty {
                // exec() preserves PID/start time but changes executable and argv. Use the
                // fresh record after socket discovery, and reject a genuinely reused PID.
                if let live = inspector.process(pid: process.identity.pid), live.identity == process.identity,
                    live.userID == process.userID, live.state != .exited
                {
                    process = live
                } else {
                    endpoints = []
                }
            }
            let provider = classifier.agent(for: process)
            guard provider != nil || !endpoints.isEmpty else { continue }
            if let provider, hasProviderAncestor(process, provider: provider, map: processMap, classifier: classifier) {
                continue
            }
            let framework = classifier.framework(for: process)
            var cpu: Double?
            if let ticks = process.cpuNanoseconds {
                if let previous = samples[process.identity], ticks >= previous.cpu, now > previous.time {
                    cpu = Double(ticks - previous.cpu) / 1_000_000_000 / (now - previous.time) * 100
                }
                nextSamples[process.identity] = Sample(cpu: ticks, time: now)
            }
            services.append(
                ServiceRecord(
                    process: process,
                    kind: provider != nil ? .agent : (framework.isDevelopment ? .server : .listener),
                    provider: provider, framework: framework.name,
                    endpoints: endpoints, cpuPercent: cpu,
                    isDesktopApplication: classifier.isDesktopAgent(process)
                ))
        }
        samples = nextSamples
        services.sort {
            if $0.kind != $1.kind { return $0.kind.rawValue < $1.kind.rawValue }
            if $0.process.projectName != $1.process.projectName {
                return $0.process.projectName.localizedStandardCompare($1.process.projectName) == .orderedAscending
            }
            return $0.id.pid < $1.id.pid
        }
        return ScanSnapshot(services: services, processCount: records.count, warning: warning)
    }

    private func hasProviderAncestor(
        _ process: ProcessRecord, provider: AgentProvider,
        map: [Int32: ProcessRecord], classifier: ServiceClassifier
    ) -> Bool {
        var parent = process.parentPID
        var visited = Set<Int32>()
        while parent > 1, visited.insert(parent).inserted, let record = map[parent] {
            if classifier.agent(for: record)?.id == provider.id { return true }
            parent = record.parentPID
        }
        return false
    }
}
