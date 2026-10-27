import Darwin
import Foundation

/// The environment a launched command runs with, and how /bin/zsh runs the command in it.
public struct ShellEnvironment: Sendable, Equatable {
    public enum Source: Sendable, Equatable {
        /// Read from the user's interactive login shell, so commands find what they find in Terminal.
        case interactive(shell: String)
        /// The app's own environment with Homebrew's folders on PATH, for a login shell.
        case fallback(FallbackReason)
    }

    public enum FallbackReason: Sendable, Equatable {
        case timedOut(seconds: Int)
        case exited(Int32)
        case noOutput
        case unsupportedShell(String)
        case launchFailed
    }

    static let beginMarker = "__BYTE_PORTS_ENV_BEGIN__"
    static let endMarker = "__BYTE_PORTS_ENV_END__"

    public let variables: [String: String]
    public let source: Source

    public init(variables: [String: String], source: Source) {
        self.variables = variables
        self.source = source
    }

    /// The arguments for /bin/zsh.
    public func arguments(for command: String) -> [String] {
        switch source {
        // A login shell would run /etc/zprofile again, whose path_helper moves the system folders to the front of the
        // resolved PATH, so Homebrew's tools would win over those of nvm or pyenv again.
        case .interactive: ["-c", command]
        case .fallback: ["-l", "-c", command]
        }
    }

    /// The variables `/usr/bin/env -0` printed between the markers. Shells may print banners or escape sequences
    /// around them. nil without both markers or without a PATH.
    static func parse(_ output: Data) -> [String: String]? {
        guard let begin = output.range(of: Data(beginMarker.utf8)),
            let end = output.range(
                of: Data(endMarker.utf8), options: .backwards, in: begin.upperBound..<output.endIndex)
        else { return nil }
        var variables: [String: String] = [:]
        for entry in output[begin.upperBound..<end.lowerBound].split(separator: 0) {
            guard let separator = entry.firstIndex(of: UInt8(ascii: "=")), separator > entry.startIndex else {
                continue
            }
            let key = String(decoding: entry[..<separator], as: UTF8.self)
            variables[key] = String(decoding: entry[(separator + 1)...], as: UTF8.self)
        }
        guard variables["PATH"]?.isEmpty == false else { return nil }
        return variables
    }

    /// The app's environment overlaid with the resolved one, without the resolving shell's own bookkeeping.
    static func merge(base: [String: String], resolved: [String: String]) -> [String: String] {
        var variables = base.merging(resolved) { $1 }
        for key in ["SHLVL", "PWD", "OLDPWD", "_"] { variables[key] = nil }
        variables["TERM"] = "dumb"
        variables["NO_COLOR"] = "1"
        return variables
    }

    /// The environment launched commands had before the shell environment was read.
    static func fallback(base: [String: String], reason: FallbackReason) -> ShellEnvironment {
        var variables = base
        variables["TERM"] = "dumb"
        variables["NO_COLOR"] = "1"
        // GUI launches have a small PATH. The login shell's configuration can extend it further.
        variables["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" + (base["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin")
        return ShellEnvironment(variables: variables, source: .fallback(reason))
    }
}

extension ShellEnvironment.Source {
    /// For the log: never a value, path or shell name.
    var logKey: String {
        switch self {
        case .interactive: "interactive"
        case .fallback(let reason): "fallback(\(reason.logKey))"
        }
    }
}

extension ShellEnvironment.FallbackReason {
    /// Why the shell environment couldn't be read, for the notice in a run's output.
    public var localizedDescription: String {
        switch self {
        case .timedOut(let seconds):
            String(
                localized: "timed out after \(seconds) s",
                comment: "Reason in launch output why the shell environment wasn't read; the argument is a number")
        case .exited(let code):
            String(
                localized: "exit code \(code)",
                comment: "Reason in launch output why the shell environment wasn't read; the argument is the code")
        case .noOutput:
            String(
                localized: "no usable output",
                comment: "Reason in launch output why the shell environment wasn't read")
        case .unsupportedShell(let name):
            String(
                localized: "“\(name)” isn't supported",
                comment: "Reason in launch output why the shell environment wasn't read; the argument is a shell")
        case .launchFailed:
            String(
                localized: "couldn't start",
                comment: "Reason in launch output why the shell environment wasn't read: the shell didn't start")
        }
    }

    var logKey: String {
        switch self {
        case .timedOut: "timedOut"
        case .exited(let code): "exited(\(code))"
        case .noOutput: "noOutput"
        case .unsupportedShell: "unsupportedShell"
        case .launchFailed: "launchFailed"
        }
    }
}

public protocol ShellEnvironmentProviding: Sendable {
    /// Changes whenever a resolved environment may have become stale.
    func fingerprint() -> String
    func resolve(base: [String: String]) async -> ShellEnvironment
}

/// Reads the environment that the user's interactive login shell sets up, by running it once with a script that prints
/// the environment between markers.
public struct InteractiveShellEnvironment: ShellEnvironmentProviding {
    public static let defaultTimeout: Duration = .seconds(10)
    static let supportedShells: Set<String> = ["zsh", "bash", "fish"]
    static let script =
        "printf '%s' '\(ShellEnvironment.beginMarker)'; /usr/bin/env -0; printf '%s' '\(ShellEnvironment.endMarker)'"

    public let shell: String
    public let home: String
    public let timeout: Duration

    public init(
        shell: String = InteractiveShellEnvironment.loginShell(), home: String = NSHomeDirectory(),
        timeout: Duration = InteractiveShellEnvironment.defaultTimeout
    ) {
        self.shell = shell
        self.home = home
        self.timeout = timeout
    }

    /// The user's shell from the user database if it is an absolute, executable zsh, bash or fish, otherwise /bin/zsh.
    /// Commands always run in /bin/zsh; only their environment comes from this shell.
    public static func loginShell() -> String {
        let recorded = withUnsafeTemporaryAllocation(of: CChar.self, capacity: 4096) { buffer -> String? in
            var record = passwd()
            var result: UnsafeMutablePointer<passwd>?
            guard getpwuid_r(getuid(), &record, buffer.baseAddress, buffer.count, &result) == 0, result != nil,
                let shell = record.pw_shell
            else { return nil }
            return String(cString: shell)
        }
        guard let recorded, recorded.hasPrefix("/"), access(recorded, X_OK) == 0,
            supportedShells.contains((recorded as NSString).lastPathComponent)
        else { return "/bin/zsh" }
        return recorded
    }

    private var shellName: String { (shell as NSString).lastPathComponent }

    /// The shell plus the modification time and size of each startup file it reads, so editing one of them, or
    /// adding or removing one, changes it.
    public func fingerprint() -> String {
        let files: [String] =
            switch shellName {
            case "zsh": [".zshenv", ".zprofile", ".zshrc", ".zlogin"]
            case "bash": [".bash_profile", ".bash_login", ".profile", ".bashrc"]
            case "fish": [".config/fish/config.fish", ".config/fish/conf.d"]
            default: []
            }
        return ([shell] + files.map { "\($0) \(Self.stamp((home as NSString).appendingPathComponent($0)))" })
            .joined(separator: "\n")
    }

    public func resolve(base: [String: String]) async -> ShellEnvironment {
        guard Self.supportedShells.contains(shellName) else {
            return .fallback(base: base, reason: .unsupportedShell(shellName))
        }
        var environment = base
        environment["TERM"] = "dumb"
        let outcome = await ShellProbe.run(
            shell, arguments: ["-l", "-i", "-c", Self.script], environment: environment, directory: home,
            timeout: timeout)
        switch outcome {
        case .launchFailed:
            return .fallback(base: base, reason: .launchFailed)
        case .timedOut:
            let (seconds, attoseconds) = timeout.components
            return .fallback(base: base, reason: .timedOut(seconds: Int(seconds) + (attoseconds > 0 ? 1 : 0)))
        case .exited(let status, let output):
            guard let resolved = ShellEnvironment.parse(output) else {
                return .fallback(base: base, reason: status == 0 ? .noOutput : .exited(status))
            }
            return ShellEnvironment(
                variables: ShellEnvironment.merge(base: base, resolved: resolved), source: .interactive(shell: shell))
        }
    }

    private static func stamp(_ path: String) -> String {
        var info = stat()
        guard stat(path, &info) == 0 else { return "missing" }
        return "\(info.st_mtimespec.tv_sec).\(info.st_mtimespec.tv_nsec) \(info.st_size)"
    }
}

/// Resolves without running a shell, for tests: a fallback, or the given variables as an interactive result.
public struct FixedShellEnvironment: ShellEnvironmentProviding {
    public let source: ShellEnvironment.Source
    public let variables: [String: String]

    public init(_ source: ShellEnvironment.Source, variables: [String: String] = [:]) {
        self.source = source
        self.variables = variables
    }

    public func fingerprint() -> String { "fixed" }

    public func resolve(base: [String: String]) async -> ShellEnvironment {
        switch source {
        case .interactive:
            ShellEnvironment(variables: ShellEnvironment.merge(base: base, resolved: variables), source: source)
        case .fallback(let reason):
            .fallback(base: base, reason: reason)
        }
    }
}

/// One run of the resolving shell. It gets a session of its own: that is also its own process group, so a timeout
/// reaches the children it started, and without a controlling terminal an interactive shell started from a Terminal
/// session can neither take over that terminal nor stop while it waits for it. The output and the exit are handled on
/// one serial queue, so the last read after the exit cannot race an earlier one, and no thread blocks while the shell
/// runs.
private final class ShellProbe: @unchecked Sendable {
    enum Outcome: Sendable {
        case exited(status: Int32, output: Data)
        case timedOut
        case launchFailed
    }

    private static let outputLimit = 1 << 20
    private let queue = DispatchQueue(label: "de.byte.ports.shell-environment")
    // Used on `queue` only.
    private var continuation: CheckedContinuation<Outcome, Never>?
    private var pid: pid_t = 0
    private var reader: Int32 = -1
    private var readSource: (any DispatchSourceRead)?
    private var exitSource: (any DispatchSourceProcess)?
    private var output = Data()

    static func run(
        _ executable: String, arguments: [String], environment: [String: String], directory: String,
        timeout: Duration
    ) async -> Outcome {
        await withCheckedContinuation { continuation in
            let probe = ShellProbe()
            probe.queue.async {
                probe.start(
                    executable, arguments: arguments, environment: environment, directory: directory, timeout: timeout,
                    continuation: continuation)
            }
        }
    }

    private func start(
        _ executable: String, arguments: [String], environment: [String: String], directory: String,
        timeout: Duration, continuation: CheckedContinuation<Outcome, Never>
    ) {
        guard let spawned = Self.spawn(executable, arguments, environment, directory) else {
            continuation.resume(returning: .launchFailed)
            return
        }
        let (pid, reader) = spawned
        self.continuation = continuation
        self.pid = pid
        self.reader = reader
        let readSource = DispatchSource.makeReadSource(fileDescriptor: reader, queue: queue)
        readSource.setEventHandler { self.drain() }
        readSource.setCancelHandler { close(reader) }
        let exitSource = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: queue)
        exitSource.setEventHandler { self.reap() }
        self.readSource = readSource
        self.exitSource = exitSource
        readSource.resume()
        exitSource.resume()
        let (seconds, attoseconds) = timeout.components
        let nanoseconds = Int(seconds) * 1_000_000_000 + Int(attoseconds / 1_000_000_000)
        queue.asyncAfter(deadline: .now() + .nanoseconds(nanoseconds)) { [weak self] in self?.expire() }
    }

    /// Reads what the pipe holds now. Output beyond the limit is discarded, so the shell never blocks on a full pipe.
    private func drain() {
        guard readSource != nil else { return }
        var buffer = [UInt8](repeating: 0, count: 16_384)
        while true {
            let count = Darwin.read(reader, &buffer, buffer.count)
            if count > 0 {
                output.append(contentsOf: buffer.prefix(min(count, Self.outputLimit - output.count)))
            } else if count == 0 {
                stopReading()
                return
            } else if errno != EINTR {
                return
            }
        }
    }

    /// The exit event can arrive before the shell is a zombie and doesn't repeat, so this waits for the zombie instead
    /// of polling once with WNOHANG. The shell is already exiting, so the wait is short.
    private func reap() {
        var status: Int32 = 0
        var result: pid_t
        repeat { result = waitpid(pid, &status, 0) } while result == -1 && errno == EINTR
        exitSource?.cancel()
        exitSource = nil
        // Everything the shell wrote is in the pipe now. Background jobs it left behind may keep the pipe open, so the
        // probe doesn't wait for the end of the output.
        drain()
        stopReading()
        finish(.exited(status: result == pid ? Self.exitCode(status) : -1, output: output))
    }

    private func expire() {
        guard continuation != nil else { return }
        // The shell isn't reaped yet, so its PID, and with it the process group, can't belong to anyone else.
        kill(-pid, SIGKILL)
        stopReading()
        finish(.timedOut)
    }

    /// Cancelling the source closes the pipe's read end.
    private func stopReading() {
        readSource?.cancel()
        readSource = nil
    }

    private func finish(_ outcome: Outcome) {
        continuation?.resume(returning: outcome)
        continuation = nil
    }

    /// WIFEXITED and WEXITSTATUS are macros Swift can't import. A signal counts as 128 plus its number, as in shells.
    private static func exitCode(_ status: Int32) -> Int32 {
        status & 0x7f == 0 ? (status >> 8) & 0xff : 128 + (status & 0x7f)
    }

    /// Starts `executable` in a new session with stdout on a pipe, stdin and stderr on /dev/null and none of the app's
    /// other descriptors. Returns its PID and the pipe's non-blocking read end.
    private static func spawn(
        _ executable: String, _ arguments: [String], _ environment: [String: String], _ directory: String
    ) -> (pid: pid_t, reader: Int32)? {
        var descriptors: [Int32] = [-1, -1]
        guard pipe(&descriptors) == 0 else { return nil }
        let (reader, writer) = (descriptors[0], descriptors[1])
        // Processes the app starts elsewhere must not inherit either end.
        _ = fcntl(reader, F_SETFD, FD_CLOEXEC)
        _ = fcntl(writer, F_SETFD, FD_CLOEXEC)
        _ = fcntl(reader, F_SETFL, fcntl(reader, F_GETFL) | O_NONBLOCK)
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&actions, writer, STDOUT_FILENO)
        posix_spawn_file_actions_addopen(&actions, STDERR_FILENO, "/dev/null", O_WRONLY, 0)
        posix_spawn_file_actions_addchdir(&actions, directory)
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        let flags = POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK
        posix_spawnattr_setflags(&attributes, Int16(flags))
        var mask = sigset_t()
        sigemptyset(&mask)
        posix_spawnattr_setsigmask(&attributes, &mask)
        var defaults = sigset_t()
        sigfillset(&defaults)
        sigdelset(&defaults, SIGKILL)
        sigdelset(&defaults, SIGSTOP)
        posix_spawnattr_setsigdefault(&attributes, &defaults)
        var pid: pid_t = 0
        let status = withCStrings([executable] + arguments) { argv in
            withCStrings(environment.map { "\($0.key)=\($0.value)" }) { envp in
                posix_spawn(&pid, executable, &actions, &attributes, argv, envp)
            }
        }
        close(writer)
        guard status == 0 else {
            close(reader)
            return nil
        }
        return (pid, reader)
    }

    private static func withCStrings<Result>(
        _ strings: [String], _ body: (UnsafePointer<UnsafeMutablePointer<CChar>?>) -> Result
    ) -> Result {
        let pointers = strings.map { strdup($0) } + [nil]
        defer { for pointer in pointers { free(pointer) } }
        return pointers.withUnsafeBufferPointer { body($0.baseAddress!) }
    }
}
