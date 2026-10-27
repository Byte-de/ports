import Foundation
import Testing

@testable import PortsCore

func process(
    _ executable: String, arguments: [String] = [], name: String = "test",
    pid: Int32 = 42, parent: Int32 = 1, uid: UInt32 = 501,
    seconds: UInt64 = 100, microseconds: UInt64 = 1, state: ProcessState = .running
) -> ProcessRecord {
    .init(
        identity: .init(pid: pid, startSeconds: seconds, startMicroseconds: microseconds),
        parentPID: parent, userID: uid, name: name, executable: executable,
        arguments: arguments.isEmpty ? [executable] : arguments, workingDirectory: "/tmp/project", state: state)
}

struct ClassifierTests {
    private let classifier = ServiceClassifier()

    @Test(arguments: [
        ("/opt/homebrew/bin/claude", "claude"),
        ("/usr/local/bin/codex", "codex"),
        ("/opt/homebrew/bin/cursor-agent", "cursor"),
        ("/usr/local/bin/gemini", "gemini"),
        ("/usr/local/bin/aider", "aider"),
    ])
    func detectsExecutable(path: String, provider: String) {
        #expect(classifier.agent(for: process(path))?.id == provider)
    }

    @Test func detectsNodePackageEntrypoints() {
        let record = process(
            "/usr/local/bin/node",
            arguments: ["node", "/opt/lib/node_modules/@anthropic-ai/claude-code/cli.js", "fix the app"])
        #expect(classifier.agent(for: record)?.id == "claude")
    }

    @Test func ignoresPromptTextAndInlinePrograms() {
        for record in [
            process("/bin/echo", arguments: ["echo", "claude"]),
            process("/usr/bin/node", arguments: ["node", "my-server.js", "codex", "claude"]),
            process("/usr/bin/python3", arguments: ["python3", "-c", "import aider"]),
            process("/bin/zsh", arguments: ["zsh", "-c", "claude"]),
            process("/usr/bin/tail", arguments: ["tail", "/tmp/codex"]),
        ] { #expect(classifier.agent(for: record) == nil) }
    }

    @Test func distinguishesDesktopApplicationAndHelper() {
        let app = process("/Applications/Codex.app/Contents/MacOS/Codex")
        let helper = process("/Applications/Codex.app/Contents/Frameworks/Codex Helper.app/Contents/MacOS/Codex Helper")
        #expect(classifier.isDesktopAgent(app))
        #expect(classifier.agent(for: helper) == nil)
    }

    @Test func recognizesFrameworkAndKeepsUnknownListeners() {
        let vite = process("/opt/homebrew/bin/node", arguments: ["node", "/tmp/project/node_modules/vite/bin/vite.js"])
        #expect(classifier.framework(for: vite).name == "Vite")
        let unknown = classifier.framework(for: process("/usr/bin/nc", name: "nc"))
        #expect(unknown.name == "nc")
        #expect(!unknown.isDevelopment)
    }

    @Test func knownNonHTTPDaemons() {
        for record in [
            process("/opt/homebrew/opt/postgresql@17/bin/postgres", arguments: ["postgres", "-D", "/tmp/data"]),
            process("/opt/homebrew/opt/redis/bin/redis-server", arguments: ["redis-server *:6379"]),
            process("/usr/local/mysql/bin/mysqld"), process("/opt/homebrew/bin/mongod"),
            process("/usr/local/bin/memcached"),
        ] { #expect(classifier.isKnownNonHTTP(record), "\(record.executable)") }
        for record in [
            process("/opt/homebrew/bin/nginx", arguments: ["nginx: master process nginx"]),
            process("/opt/homebrew/bin/caddy", arguments: ["caddy", "run"]),
            process("/usr/bin/python3", arguments: ["python3", "-m", "http.server", "8000"]),
        ] { #expect(!classifier.isKnownNonHTTP(record), "\(record.command)") }
    }

    @Test func doesNotMistakeBundledCLIForDesktopApplication() {
        let backend = process(
            "/Applications/ChatGPT.app/Contents/Resources/CodexCLI.app/Contents/MacOS/codex",
            arguments: ["codex", "exec-server"])
        #expect(!classifier.isDesktopAgent(backend))
        #expect(classifier.agent(for: backend)?.name == "Codex service")
    }

    @Test func supportsCustomRulesWithExactMatching() {
        let custom = ServiceClassifier(customRules: [.init(name: "My agent", executableName: "my-agent")])
        #expect(custom.agent(for: process("/opt/bin/my-agent"))?.name == "My agent")
        #expect(custom.agent(for: process("/opt/bin/my-agent-helper")) == nil)
    }

    @Test func emptyExecutablePathIsNotResolvedAgainstCurrentDirectory() {
        // URL(fileURLWithPath: "") names the current directory; a rule matching it must not match an unknown path.
        let directory = (FileManager.default.currentDirectoryPath as NSString).lastPathComponent
        let custom = ServiceClassifier(customRules: [.init(name: "Directory", executableName: directory)])
        let record = process("", name: "unknown")
        #expect(custom.agent(for: record) == nil)
        #expect(custom.framework(for: record).name == "unknown")
    }
}
