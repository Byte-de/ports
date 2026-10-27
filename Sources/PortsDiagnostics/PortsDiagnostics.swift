import Darwin
import Foundation
import PortsCore

@main
struct PortsDiagnostics {
    static func main() async {
        do { try await run() } catch {
            FileHandle.standardError.write(Data("FAIL: \(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }

    private static func run() async throws {
        if let index = CommandLine.arguments.firstIndex(of: "--fixture-server")
            ?? CommandLine.arguments.firstIndex(of: "--fixture-http-server"),
            CommandLine.arguments.indices.contains(index + 1),
            let port = UInt16(CommandLine.arguments[index + 1])
        {
            try fixtureServer(port: port, http: CommandLine.arguments.contains("--fixture-http-server"))
        } else if let index = CommandLine.arguments.firstIndex(of: "--tunnel-integration"),
            CommandLine.arguments.indices.contains(index + 1)
        {
            try await tunnelIntegration(app: URL(fileURLWithPath: CommandLine.arguments[index + 1]))
        } else if CommandLine.arguments.contains("--integration") {
            try await integration()
        } else if CommandLine.arguments.contains("--listener-parity") {
            try listenerParity()
        } else if let index = CommandLine.arguments.firstIndex(of: "--benchmark") {
            guard CommandLine.arguments.indices.contains(index + 1),
                let scans = Int(CommandLine.arguments[index + 1]), scans > 0
            else { throw MonitorError.scanFailed("Usage: ports-diagnostics --benchmark <scans>") }
            try await benchmark(scans: scans)
        } else {
            // One scanner for both scans, so the warm one reuses the argv cache like the app's scan loop.
            let scanner = ProcessScanner()
            let clock = ContinuousClock()
            var start = clock.now
            _ = try await scanner.scan()
            let cold = start.duration(to: clock.now)
            start = clock.now
            let snapshot = try await scanner.scan()
            let warm = start.duration(to: clock.now)
            // Whole milliseconds: JSONSerialization prints fractions with 17 significant digits.
            func wholeMilliseconds(_ duration: Duration) -> Int { Int((duration / .milliseconds(1)).rounded()) }
            let counts: [String: Any] = [
                "processes": snapshot.processCount,
                "agents": snapshot.services.filter { $0.kind == .agent }.count,
                "developmentServers": snapshot.services.filter { $0.kind == .server }.count,
                "tcpListenerProcesses": snapshot.services.filter { !$0.endpoints.isEmpty }.count,
                "scanMilliseconds": ["cold": wholeMilliseconds(cold), "warm": wholeMilliseconds(warm)],
                "warning": snapshot.warning as Any? ?? NSNull(),
            ]
            let data = try JSONSerialization.data(withJSONObject: counts, options: [.prettyPrinted, .sortedKeys])
            print(String(decoding: data, as: UTF8.self))
        }
    }

    /// Repeated scans with one scanner, like the app's scan loop. The first scan only warms
    /// per-process state and is not reported. Children CPU reveals any tool a scan spawns.
    private static func benchmark(scans: Int) async throws {
        let scanner = ProcessScanner()
        let clock = ContinuousClock()
        var snapshot = try await scanner.scan()
        var wall: [Double] = []
        var selfCPU = 0.0
        var childrenCPU = 0.0
        for _ in 0..<scans {
            let selfBefore = cpuMilliseconds(RUSAGE_SELF)
            let childrenBefore = cpuMilliseconds(RUSAGE_CHILDREN)
            let start = clock.now
            snapshot = try await scanner.scan()
            wall.append(start.duration(to: clock.now) / .milliseconds(1))
            selfCPU += cpuMilliseconds(RUSAGE_SELF) - selfBefore
            childrenCPU += cpuMilliseconds(RUSAGE_CHILDREN) - childrenBefore
            // Without listener discovery the timings would not describe a real scan.
            if let warning = snapshot.warning { throw MonitorError.scanFailed(warning) }
        }
        wall.sort()
        // Nearest-rank percentile.
        func percentile(_ percent: Int) -> Double { rounded(wall[max(0, (wall.count * percent + 99) / 100 - 1)]) }
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        let report = BenchmarkReport(
            scans: scans, processes: snapshot.processCount, services: snapshot.services.count,
            wallMilliseconds: .init(p50: percentile(50), p95: percentile(95), max: rounded(wall[wall.count - 1])),
            cpuMillisecondsPerScan: .init(
                self: rounded(selfCPU / Double(scans)), children: rounded(childrenCPU / Double(scans))),
            // Darwin reports ru_maxrss in bytes.
            maxResidentMegabytes: rounded(Double(usage.ru_maxrss) / 1_048_576))
        // JSONEncoder prints the shortest decimal form; JSONSerialization would print 78.400000000000006.
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        print(String(decoding: try encoder.encode(report), as: UTF8.self))
    }

    /// User plus system CPU time; RUSAGE_CHILDREN only counts children that were already reaped.
    private static func cpuMilliseconds(_ who: Int32) -> Double {
        var usage = rusage()
        getrusage(who, &usage)
        return milliseconds(usage.ru_utime) + milliseconds(usage.ru_stime)
    }

    private static func milliseconds(_ time: timeval) -> Double {
        Double(time.tv_sec) * 1000 + Double(time.tv_usec) / 1000
    }

    private static func rounded(_ value: Double) -> Double { (value * 10).rounded() / 10 }

    private static func integration() async throws {
        let launcher = LaunchManager()
        let scanner = ProcessScanner()
        let controller = ProcessController()
        let port = UInt16.random(in: 49_200...60_000)
        let executable = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.path
        let configuration = LaunchConfiguration(
            name: "Byte Ports integration fixture",
            command: "printf 'fixture ready\\n'; exec \(ShellEscaping.quote(executable)) --fixture-server \(port)",
            directory: FileManager.default.currentDirectoryPath)
        let job = try await launcher.start(configuration)
        var stage = "discovery"
        do {
            var found: ServiceRecord?
            for _ in 0..<10 {
                let snapshot = try await scanner.scan()
                found = snapshot.services.first { $0.endpoints.contains { $0.port == port } }
                if found != nil { break }
                try await Task.sleep(for: .milliseconds(100))
            }
            guard let service = found else {
                let output = await launcher.output(for: job)
                throw MonitorError.scanFailed("Fixture listener not detected. Test output: \(output)")
            }
            stage = "pause"
            try controller.perform(.pause, on: service.process)
            try await Task.sleep(for: .milliseconds(30))
            guard NativeProcessInspector().process(pid: service.id.pid)?.state == .paused else {
                throw MonitorError.scanFailed("SIGSTOP not observed")
            }
            stage = "resume"
            try controller.perform(.resume, on: service.process)
            guard await launcher.output(for: job).contains("fixture ready") else {
                throw MonitorError.scanFailed("Captured output missing")
            }
            stage = "restart"
            guard try await launcher.restart(job) == .stopped else {
                throw MonitorError.scanFailed("Fixture did not stop for the restart")
            }
            guard let slot = await launcher.records().first(where: { $0.id == job }), slot.runCount == 2 else {
                throw MonitorError.scanFailed("Restart did not reuse the job's slot")
            }
            try await Task.sleep(for: .milliseconds(150))
            let restarted = try await scanner.scan()
            guard
                restarted.services.contains(where: { $0.endpoints.contains { $0.port == port } && $0.id != service.id })
            else {
                throw MonitorError.scanFailed("Restart did not create a new listener")
            }
            stage = "stop"
            guard try await launcher.stop(job) == .stopped else {
                throw MonitorError.scanFailed("Fixture did not stop within the grace period")
            }
            guard await launcher.status(for: job) == .stopped else {
                throw MonitorError.scanFailed("Stopped fixture not reported as stopped")
            }
            let final = try await scanner.scan()
            guard !final.services.contains(where: { $0.endpoints.contains { $0.port == port } }) else {
                throw MonitorError.scanFailed("Fixture listener still active")
            }
            print("PASS: live TCP detection, identity, pause, resume, log capture, restart, graceful stop, cleanup")
        } catch {
            _ = try? await launcher.stop(job)
            throw MonitorError.scanFailed("\(stage): \(error.localizedDescription)")
        }
    }

    /// Compares native listener discovery with lsof for this user's processes. Sockets can open or close while lsof
    /// runs, so lsof must lie within the union of a native snapshot before and after it and contain their intersection.
    private static func listenerParity() throws {
        let pids = try NativeProcessInspector().processes().map(\.identity.pid)
        let discovery = NativeListenerDiscovery()
        let before = Set(try discovery.listeners(of: pids).map(parityKey))
        let lsof = Process()
        let pipe = Pipe()
        lsof.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        lsof.arguments = ["-nP", "-a", "-u", String(getuid()), "-iTCP", "-sTCP:LISTEN", "-Fpn"]
        lsof.standardOutput = pipe
        lsof.standardError = FileHandle.nullDevice
        lsof.standardInput = FileHandle.nullDevice
        try lsof.run()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        lsof.waitUntilExit()
        // lsof uses 1 for a successful search without matching listeners.
        guard lsof.terminationStatus == 0 || (lsof.terminationStatus == 1 && output.isEmpty) else {
            throw MonitorError.scanFailed("lsof exited with status \(lsof.terminationStatus)")
        }
        let owned = Set(pids)
        let expected = Set(ListenerParser.parse(output).filter { owned.contains($0.pid) }.map(parityKey))
        let after = Set(try discovery.listeners(of: pids).map(parityKey))
        let missing = expected.subtracting(before.union(after)).sorted()
        let unexpected = before.intersection(after).subtracting(expected).sorted()
        guard missing.isEmpty, unexpected.isEmpty else {
            throw MonitorError.scanFailed(
                "Listener parity: missing natively \(missing), not reported by lsof \(unexpected)")
        }
        print("PASS: native TCP listener discovery matches lsof (\(expected.count) listeners)")
    }

    /// lsof prints an IPv6-only wildcard as "*", like a dual-stack one.
    private static func parityKey(_ endpoint: ListeningEndpoint) -> String {
        "\(endpoint.pid) \(endpoint.address == "::" ? "*" : endpoint.address) \(endpoint.port)"
    }

    /// Explicit opt-in only: shares a new constant-response fixture, never a user's server or files.
    private static func tunnelIntegration(app: URL) async throws {
        let manager = CloudflareTunnelManager(
            client: app.appending(path: "Contents/Helpers/cloudflared"),
            runner: app.appending(path: "Contents/Helpers/ports-tunnel-runner"))
        let launcher = LaunchManager()
        let port = UInt16.random(in: 49_200...60_000)
        let executable = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.path
        let job = try await launcher.start(
            .init(
                name: "Byte Ports tunnel integration fixture",
                command: "exec \(ShellEscaping.quote(executable)) --fixture-http-server \(port)",
                directory: "/private/tmp"))
        do {
            var found: ServiceRecord?
            for _ in 0..<20 {
                found = try await ProcessScanner().scan().services.first { $0.endpoints.contains { $0.port == port } }
                if found != nil { break }
                try await Task.sleep(for: .milliseconds(100))
            }
            guard let found, let endpoint = found.endpoints.first(where: { $0.port == port }) else {
                throw MonitorError.scanFailed("Tunnel fixture did not start")
            }
            let service = ServiceRecord(
                process: found.process, kind: .server, framework: "HTTP fixture", endpoints: [endpoint])
            let target = try TunnelTarget(service: service, endpoint: endpoint)
            try await manager.start(target)
            var publicURL: URL?
            for _ in 0..<100 {
                let record = await manager.records().first
                if record?.phase == .ready {
                    publicURL = record?.publicURL
                    break
                }
                if record?.phase == .failed { throw MonitorError.scanFailed(record?.message ?? "Tunnel failed") }
                try await Task.sleep(for: .milliseconds(500))
            }
            guard let publicURL else { throw MonitorError.scanFailed("Tunnel did not become ready within 50 s") }
            FileHandle.standardOutput.write(Data("Temporary fixture URL: \(publicURL.absoluteString)\n".utf8))
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = 5
            config.timeoutIntervalForResource = 5
            let session = URLSession(configuration: config)
            defer { session.invalidateAndCancel() }
            let (initialData, initialResponse) = try await session.data(from: target.id.origin)
            guard (initialResponse as? HTTPURLResponse)?.statusCode == 200,
                String(decoding: initialData, as: UTF8.self) == "Byte Ports tunnel integration fixture\n"
            else {
                throw MonitorError.scanFailed("Local HTTP fixture failed before public request")
            }
            var reached = false
            var lastFailure = "No response"
            for _ in 0..<15 {
                do {
                    let (data, response) = try await session.data(from: publicURL)
                    let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                    let body = String(decoding: data, as: UTF8.self)
                    if code == 200 && body == "Byte Ports tunnel integration fixture\n" {
                        reached = true
                        break
                    }
                    lastFailure = "HTTP \(code): \(body.prefix(160))"
                } catch { lastFailure = error.localizedDescription }
                try await Task.sleep(for: .seconds(1))
            }
            guard reached else {
                throw MonitorError.scanFailed("Public HTTPS fixture was not reachable: \(lastFailure)")
            }
            try await manager.stop(target.id)
            guard await manager.records().first?.phase == .stopped else { throw TunnelError.couldNotStop }
            let (localData, _) = try await session.data(from: target.id.origin)
            guard String(decoding: localData, as: UTF8.self) == "Byte Ports tunnel integration fixture\n" else {
                throw MonitorError.scanFailed("Stopping the share affected the local server")
            }
            let remote = try? await session.data(from: publicURL)
            guard (remote?.1 as? HTTPURLResponse)?.statusCode != 200 else {
                throw MonitorError.scanFailed("Public endpoint remained reachable after stop")
            }
            try await manager.shutdown()
            try await launcher.stop(job)
            print(
                "PASS: real Cloudflare client, connected status, public HTTPS fixture, share revoked, local server preserved, cleanup"
            )
        } catch {
            try? await manager.shutdown()
            _ = try? await launcher.stop(job)
            throw error
        }
    }

    /// A minimal listener owned by the test; no files or user data are served.
    private static func fixtureServer(port: UInt16, http: Bool = false) throws {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw MonitorError.scanFailed("socket: \(errno)") }
        defer { close(descriptor) }
        var reuse: Int32 = 1
        _ = setsockopt(descriptor, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard result == 0, listen(descriptor, 4) == 0 else { throw MonitorError.scanFailed("bind/listen: \(errno)") }
        while true {
            let client = accept(descriptor, nil, nil)
            if client >= 0 {
                if http {
                    var timeout = timeval(tv_sec: 2, tv_usec: 0)
                    _ = setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
                    _ = setsockopt(client, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
                    var noSigpipe: Int32 = 1
                    _ = setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSigpipe, socklen_t(MemoryLayout<Int32>.size))
                    var request = [UInt8](repeating: 0, count: 4096)
                    if recv(client, &request, request.count, 0) > 0 {
                        let body = "Byte Ports tunnel integration fixture\n"
                        let response = Data(
                            "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: \(body.utf8.count)\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n\(body)"
                                .utf8)
                        _ = response.withUnsafeBytes { send(client, $0.baseAddress, $0.count, 0) }
                    }
                }
                close(client)
            } else if errno != EINTR {
                throw MonitorError.scanFailed("accept: \(errno)")
            }
        }
    }
}

/// Output of --benchmark. Keep the keys stable so recorded baselines stay comparable.
private struct BenchmarkReport: Encodable {
    struct Percentiles: Encodable { let p50, p95, max: Double }
    struct CPUPerScan: Encodable { let `self`, children: Double }
    let scans, processes, services: Int
    let wallMilliseconds: Percentiles
    let cpuMillisecondsPerScan: CPUPerScan
    let maxResidentMegabytes: Double
}
