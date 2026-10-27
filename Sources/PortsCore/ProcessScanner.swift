import Darwin
import Dispatch
import Foundation
import ProcessBridge

public protocol ListenerDiscovering: Sendable {
    func listeners(of pids: [Int32]) throws -> [ListeningEndpoint]
}

/// Reads listening TCP sockets of the given processes through libproc, without a subprocess per scan.
public struct NativeListenerDiscovery: ListenerDiscovering {
    public init() {}

    public func listeners(of pids: [Int32]) throws -> [ListeningEndpoint] {
        var buffer = [DSListener](repeating: DSListener(), count: 32)
        var endpoints = Set<ListeningEndpoint>()
        var inspected = 0
        for pid in pids {
            guard let found = read(pid, into: &buffer) else { continue }
            inspected += 1
            endpoints.formUnion(found)
        }
        // Single processes may exit or be protected; only a total failure means discovery is broken.
        if !pids.isEmpty && inspected == 0 {
            throw MonitorError.scanFailed(
                String(
                    localized: "The TCP listeners could not be queried.",
                    comment: "Scan warning when listening ports could not be read"))
        }
        return endpoints.sorted {
            if $0.pid != $1.pid { return $0.pid < $1.pid }
            if $0.port != $1.port { return $0.port < $1.port }
            return $0.address < $1.address
        }
    }

    /// nil when the process is gone or belongs to another user.
    public func listeners(of pid: Int32) -> [ListeningEndpoint]? {
        var buffer = [DSListener](repeating: DSListener(), count: 32)
        return read(pid, into: &buffer)
    }

    private func read(_ pid: Int32, into buffer: inout [DSListener]) -> [ListeningEndpoint]? {
        func fill() -> Int {
            Int(buffer.withUnsafeMutableBufferPointer { ds_read_tcp_listeners(pid, $0.baseAddress, Int32($0.count)) })
        }
        var count = fill()
        // The reused buffer grows once; listeners opened in between show up in the next scan.
        if count > buffer.count {
            buffer = [DSListener](repeating: DSListener(), count: count + 16)
            count = fill()
        }
        guard count >= 0 else { return nil }
        return buffer.prefix(count).map { listener in
            let address = withUnsafeBytes(of: listener.address) {
                String(decoding: $0.prefix(while: { $0 != 0 }), as: UTF8.self)
            }
            return ListeningEndpoint(pid: pid, address: address, port: listener.port)
        }
    }
}

public actor ProcessScanner {
    private struct Sample: Sendable {
        let cpu: UInt64
        let time: TimeInterval
    }
    // Scans are short synchronous libproc work; a utility queue keeps them off the cooperative pool.
    private let queue = DispatchSerialQueue(label: "scanner", qos: .utility)
    private let inspector: any ProcessInspecting
    private let listenerDiscovery: any ListenerDiscovering
    private var samples: [ProcessIdentity: Sample] = [:]
    private var argumentCache = ArgumentCache()

    public nonisolated var unownedExecutor: UnownedSerialExecutor { queue.asUnownedSerialExecutor() }

    public init(
        inspector: any ProcessInspecting = NativeProcessInspector(),
        listenerDiscovery: any ListenerDiscovering = NativeListenerDiscovery()
    ) {
        self.inspector = inspector
        self.listenerDiscovery = listenerDiscovery
    }

    public func scan(customRules: [AgentRule] = []) throws -> ScanSnapshot {
        let clock = ContinuousClock()
        let start = clock.now
        let records = try inspector.processes(reusing: &argumentCache).filter { $0.state != .exited }
        let processMap = Dictionary(records.map { ($0.identity.pid, $0) }, uniquingKeysWith: { first, _ in first })
        var warning: String?
        var listeners: [ListeningEndpoint] = []
        let pids = records.map(\.identity.pid)
        do {
            listeners = try listenerDiscovery.listeners(of: pids)
        } catch {
            PortsLog.scan.error("Listener discovery failed for \(pids.count, privacy: .public) processes")
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
        services.sort(by: ServiceRecord.displayOrder)
        let milliseconds = Int((start.duration(to: clock.now) / .milliseconds(1)).rounded())
        if milliseconds > 1000 {
            PortsLog.scan.notice(
                "Slow scan: \(services.count, privacy: .public) services of \(records.count, privacy: .public) processes in \(milliseconds, privacy: .public) ms"
            )
        } else {
            PortsLog.scan.debug(
                "Scan: \(services.count, privacy: .public) services of \(records.count, privacy: .public) processes in \(milliseconds, privacy: .public) ms"
            )
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
