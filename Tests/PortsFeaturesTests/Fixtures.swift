import PortsCore

/// Agents get a provider, so their title is the provider name. Endpoints listen on loopback.
func service(
    _ kind: ServiceKind, pid: Int32, title: String, directory: String? = nil, ports: [UInt16] = []
) -> ServiceRecord {
    let process = ProcessRecord(
        identity: .init(pid: pid, startSeconds: 100), name: title.lowercased(),
        executable: "/usr/local/bin/\(title.lowercased())",
        workingDirectory: directory)
    return ServiceRecord(
        process: process, kind: kind,
        provider: kind == .agent ? AgentProvider(id: title.lowercased(), name: title) : nil,
        framework: kind == .agent ? "Agent" : title,
        endpoints: ports.map { ListeningEndpoint(pid: pid, address: "127.0.0.1", port: $0) })
}
