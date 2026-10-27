import Darwin
import Foundation
import Testing

@testable import PortsCore

struct ShellEnvironmentTests {
    private static let begin = "__BYTE_PORTS_ENV_BEGIN__"
    private static let end = "__BYTE_PORTS_ENV_END__"

    @Test func parseIgnoresNoiseAroundMarkers() throws {
        let output = Data(
            ("Last login: today\n\u{1B}]7;file://mac/\u{7}" + Self.begin
                + "PATH=/nvm/bin:/usr/bin\0OPTIONS=a=b\0MULTI=one\ntwo\0=ignored\0" + Self.end + "logout\n").utf8)
        let variables = try #require(ShellEnvironment.parse(output))
        #expect(variables == ["PATH": "/nvm/bin:/usr/bin", "OPTIONS": "a=b", "MULTI": "one\ntwo"])
    }

    @Test func parseRejectsMissingMarkersOrEmptyPath() {
        #expect(ShellEnvironment.parse(Data("PATH=/usr/bin\0".utf8)) == nil)
        #expect(ShellEnvironment.parse(Data((Self.begin + "PATH=/usr/bin\0").utf8)) == nil)
        #expect(ShellEnvironment.parse(Data(("PATH=/usr/bin\0" + Self.end).utf8)) == nil)
        #expect(ShellEnvironment.parse(Data((Self.end + "PATH=/usr/bin\0" + Self.begin).utf8)) == nil)
        #expect(ShellEnvironment.parse(Data((Self.begin + "PATH=\0HOME=/Users/a\0" + Self.end).utf8)) == nil)
        #expect(ShellEnvironment.parse(Data((Self.begin + "HOME=/Users/a\0" + Self.end).utf8)) == nil)
    }

    @Test func mergeDropsShellBookkeepingAndForcesDumbTerminal() {
        let merged = ShellEnvironment.merge(
            base: ["PATH": "/usr/bin:/bin", "LANG": "de_DE.UTF-8", "TERM": "xterm"],
            resolved: [
                "PATH": "/nvm/bin:/usr/bin:/bin", "NVM_DIR": "/Users/a/.nvm", "SHLVL": "1", "PWD": "/Users/a",
                "OLDPWD": "/", "_": "/usr/bin/env", "TERM": "xterm-256color",
            ])
        #expect(
            merged == [
                "PATH": "/nvm/bin:/usr/bin:/bin", "NVM_DIR": "/Users/a/.nvm", "LANG": "de_DE.UTF-8", "TERM": "dumb",
                "NO_COLOR": "1",
            ])
    }

    @Test func interactiveArgumentsAreNonLoginFallbackAreLogin() {
        let interactive = ShellEnvironment(variables: [:], source: .interactive(shell: "/bin/zsh"))
        #expect(interactive.arguments(for: "npm run dev") == ["-c", "npm run dev"])
        let fallback = ShellEnvironment.fallback(
            base: ["PATH": "/usr/bin:/bin", "HOME": "/Users/a"], reason: .noOutput)
        #expect(fallback.arguments(for: "npm run dev") == ["-l", "-c", "npm run dev"])
        #expect(fallback.source == .fallback(.noOutput))
        #expect(
            fallback.variables == [
                "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin", "HOME": "/Users/a", "TERM": "dumb",
                "NO_COLOR": "1",
            ])
        #expect(
            ShellEnvironment.fallback(base: [:], reason: .launchFailed).variables["PATH"]
                == "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin")
    }

    @Test func resolverReadsFakeNoisyShell() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        // The resolver runs `<shell> -l -i -c <script>`, so the script is the fourth argument.
        let shell = try fakeShell(
            in: directory,
            """
            printf 'banner\\n'
            printf 'noise' >&2
            export PATH="/fake/bin:$PATH" FROM_RC=yes ARGUMENTS="$1 $2 $3" STARTED_IN="$(pwd -P)"
            exec /bin/sh -c "$4"
            """)
        let resolver = InteractiveShellEnvironment(shell: shell, home: directory.path, timeout: .seconds(5))
        let environment = await resolver.resolve(base: ["PATH": "/usr/bin:/bin", "LANG": "de_DE.UTF-8"])
        #expect(environment.source == .interactive(shell: shell))
        #expect(environment.variables["PATH"] == "/fake/bin:/usr/bin:/bin")
        #expect(environment.variables["FROM_RC"] == "yes")
        #expect(environment.variables["ARGUMENTS"] == "-l -i -c")
        #expect(environment.variables["STARTED_IN"] == realPath(directory.path))
        #expect(environment.variables["LANG"] == "de_DE.UTF-8")
        #expect(environment.variables["TERM"] == "dumb")
        #expect(environment.variables["NO_COLOR"] == "1")
        #expect(environment.variables["PWD"] == nil)
        #expect(environment.variables["_"] == nil)
    }

    @Test func resolverTimesOutToFallback() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let pidFile = directory.appending(path: "child.pid").path
        // The shell waits for a child of its own, which the timeout must end too. A new script can take a few hundred
        // milliseconds to start, more on a loaded machine, so the timeout leaves it time to write the child's PID.
        let shell = try fakeShell(in: directory, #"sleep 30 & printf '%s' "$!" > "$CHILD_PID_FILE"; wait"#)
        let resolver = InteractiveShellEnvironment(shell: shell, home: directory.path, timeout: .milliseconds(1900))
        let clock = ContinuousClock()
        let started = clock.now
        let environment = await resolver.resolve(base: ["PATH": "/usr/bin:/bin", "CHILD_PID_FILE": pidFile])
        #expect(started.duration(to: clock.now) < .seconds(4))
        #expect(environment.source == .fallback(.timedOut(seconds: 2)))
        #expect(environment.variables["PATH"] == "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin")
        // Without the file the group was killed before the shell forked, so there is no child to leak.
        guard let text = try? String(contentsOfFile: pidFile, encoding: .utf8) else { return }
        let child = try #require(Int32(text))
        var gone = false
        for _ in 0..<40 where !gone {
            gone = kill(child, 0) == -1 && errno == ESRCH
            if !gone { try await Task.sleep(for: .milliseconds(50)) }
        }
        #expect(gone)
    }

    @Test func resolverExitWithoutMarkersFallsBack() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let failing = try fakeShell(in: directory, named: "zsh", "printf 'no markers'; exit 3")
        let base = ["PATH": "/usr/bin:/bin"]
        let exited = await InteractiveShellEnvironment(shell: failing, home: directory.path).resolve(base: base)
        #expect(exited.source == .fallback(.exited(3)))
        let silent = try fakeShell(in: directory, named: "bash", "printf 'no markers'")
        let empty = await InteractiveShellEnvironment(shell: silent, home: directory.path).resolve(base: base)
        #expect(empty.source == .fallback(.noOutput))
        let missing = await InteractiveShellEnvironment(shell: directory.appending(path: "fish").path).resolve(
            base: base)
        #expect(missing.source == .fallback(.launchFailed))
        let other = await InteractiveShellEnvironment(shell: "/bin/tcsh").resolve(base: base)
        #expect(other.source == .fallback(.unsupportedShell("tcsh")))
        #expect(other.variables["PATH"] == "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin")
    }

    @Test func fingerprintChangesWhenRcFileChanges() throws {
        let home = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let zsh = InteractiveShellEnvironment(shell: "/bin/zsh", home: home.path)
        let empty = zsh.fingerprint()
        #expect(zsh.fingerprint() == empty)
        let rc = home.appending(path: ".zshrc")
        try Data("export A=1\n".utf8).write(to: rc)
        let created = zsh.fingerprint()
        #expect(created != empty)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: -60)], ofItemAtPath: rc.path)
        #expect(zsh.fingerprint() != created)
        // Another shell reads other files.
        #expect(InteractiveShellEnvironment(shell: "/bin/bash", home: home.path).fingerprint() != zsh.fingerprint())
    }

    @Test func loginShellIsAnAbsoluteSupportedShell() {
        let shell = InteractiveShellEnvironment.loginShell()
        #expect(shell.hasPrefix("/"))
        #expect(InteractiveShellEnvironment.supportedShells.contains((shell as NSString).lastPathComponent))
    }

    /// The key of a formatted text is its format; the cases with an argument use the number 7 or the name “nu”.
    @Test(
        arguments: [
            (.timedOut(seconds: 7), "timed out after %lld s"),
            (.exited(7), "exit code %d"),
            (.noOutput, "no usable output"),
            (.unsupportedShell("nu"), "“%@” isn't supported"),
            (.launchFailed, "couldn't start"),
        ] as [(ShellEnvironment.FallbackReason, String)])
    func fallbackReasonsHaveGermanText(reason: ShellEnvironment.FallbackReason, key: String) throws {
        let expected =
            switch reason {
            case .unsupportedShell(let name): String(format: key, name)
            default: String(format: key, 7)
            }
        #expect(reason.localizedDescription == expected)
        let german = try #require(LocalizationTable.bundle("de"))
        #expect(german.localizedString(forKey: key, value: nil, table: nil) != key)
        let notice = "[%@] Couldn't load your shell environment (%@). The command runs with the login environment."
        #expect(german.localizedString(forKey: notice, value: nil, table: nil) != notice)
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appending(path: "ShellEnvironmentTests-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// An executable sh script with a supported shell's name, so the resolver accepts it.
    private func fakeShell(in directory: URL, named name: String = "zsh", _ body: String) throws -> String {
        let url = directory.appending(path: name)
        try Data("#!/bin/sh\n\(body)\n".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url.path
    }

    private func realPath(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}
