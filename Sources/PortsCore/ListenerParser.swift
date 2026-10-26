import Foundation

public enum ListenerParser {
    /// lsof's field format is stable across command names containing whitespace.
    public static func parse(_ output: String) -> [ListeningEndpoint] {
        var pid: Int32?
        var endpoints = Set<ListeningEndpoint>()
        for line in output.split(separator: "\n") {
            guard let field = line.first else { continue }
            let value = line.dropFirst()
            if field == "p" { pid = Int32(value) }
            guard field == "n", let owner = pid, owner > 0,
                let colon = value.lastIndex(of: ":"),
                let port = UInt16(value[value.index(after: colon)...]), port > 0
            else { continue }
            let address = String(value[..<colon]).trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            guard !address.isEmpty else { continue }
            endpoints.insert(ListeningEndpoint(pid: owner, address: address, port: port))
        }
        return endpoints.sorted {
            if $0.pid != $1.pid { return $0.pid < $1.pid }
            if $0.port != $1.port { return $0.port < $1.port }
            return $0.address < $1.address
        }
    }
}
