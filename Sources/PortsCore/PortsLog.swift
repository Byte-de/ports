import OSLog

/// Unified logging for support cases. Every interpolation states its privacy explicitly: paths, commands, project
/// names and URLs stay private; counts, states and codes are public.
///
/// Levels: `debug` for per-scan summaries and surface changes (never persisted), `info` for diagnostic detail,
/// `notice` for user-relevant state changes and `error` for failures a user may report. `fault` stays unused.
///
/// Public: counts, durations, PIDs, ports, exit codes, errno, enum states, versions, random job and session UUIDs.
/// Private: paths, working directories, executables, project names, commands, origin and public URLs, error
/// descriptions. Never logged: external argv, environment values, job output, search text.
///
/// Messages are English and never localized. `Scripts/check-log-privacy.py` enforces these rules in `lint.sh`.
public enum PortsLog {
    /// Equals CFBundleIdentifier, so one `log show --predicate 'subsystem == "de.byte.ports"'` covers every event.
    public static let subsystem = "de.byte.ports"
    public static let scan = Logger(subsystem: subsystem, category: "scan")
    public static let launch = Logger(subsystem: subsystem, category: "launch")
    public static let process = Logger(subsystem: subsystem, category: "process")
    public static let tunnel = Logger(subsystem: subsystem, category: "tunnel")
    public static let update = Logger(subsystem: subsystem, category: "update")
    public static let persistence = Logger(subsystem: subsystem, category: "persistence")
    public static let lifecycle = Logger(subsystem: subsystem, category: "lifecycle")
    public static let ui = Logger(subsystem: subsystem, category: "ui")
}
