import Foundation

public struct AgentRule: Codable, Sendable, Identifiable, Equatable {
    public var id: UUID
    public var name: String
    public var executableName: String

    public init(id: UUID = UUID(), name: String, executableName: String) {
        self.id = id
        self.name = name
        self.executableName = executableName
    }
}

/// Matches an executable or its entry script, never arbitrary prompt text.
public struct ServiceClassifier: Sendable {
    public var customRules: [AgentRule]

    public init(customRules: [AgentRule] = []) { self.customRules = customRules }

    public static let providers: [(names: Set<String>, provider: AgentProvider)] = [
        (["claude", "claude-code"], .init(id: "claude", name: "Claude Code", symbol: "asterisk")),
        (["codex"], .init(id: "codex", name: "Codex", symbol: "command")),
        (["cursor-agent", "cursor"], .init(id: "cursor", name: "Cursor", symbol: "cursorarrow")),
        (["opencode"], .init(id: "opencode", name: "OpenCode", symbol: "chevron.left.forwardslash.chevron.right")),
        (["aider"], .init(id: "aider", name: "Aider", symbol: "terminal")),
        (["copilot", "github-copilot"], .init(id: "copilot", name: "GitHub Copilot", symbol: "eyeglasses")),
        (["gemini"], .init(id: "gemini", name: "Gemini CLI", symbol: "sparkle")),
        (["goose"], .init(id: "goose", name: "Goose", symbol: "bird")),
        (["qwen", "qwen-code"], .init(id: "qwen", name: "Qwen Code")),
        (["kimi", "kimi-cli"], .init(id: "kimi", name: "Kimi Code")),
        (["droid"], .init(id: "droid", name: "Factory Droid", symbol: "square.stack.3d.up")),
        (["vibe"], .init(id: "vibe", name: "Mistral Vibe", symbol: "wind")),
        (["kiro-cli"], .init(id: "kiro", name: "Kiro")),
        (["hermes"], .init(id: "hermes", name: "Hermes")),
        (["pi"], .init(id: "pi", name: "Pi", symbol: "pi")),
        (["amp"], .init(id: "amp", name: "Amp", symbol: "bolt")),
        (["cline"], .init(id: "cline", name: "Cline")),
        (["kilo", "kilo-code"], .init(id: "kilo", name: "Kilo Code")),
    ]

    public func agent(for process: ProcessRecord) -> AgentProvider? {
        if let desktop = desktopProvider(for: process) { return desktop }
        let candidates = entryNames(process)
        for rule in customRules where candidates.contains(rule.executableName.lowercased()) {
            return AgentProvider(id: rule.id.uuidString, name: rule.name)
        }
        for entry in Self.providers where !entry.names.isDisjoint(with: candidates) {
            if entry.provider.id == "codex",
                process.arguments.dropFirst().prefix(2).contains(where: { ["exec-server", "app-server"].contains($0) })
            {
                return AgentProvider(id: "codex", name: "Codex-Dienst", symbol: "command")
            }
            return entry.provider
        }
        let script = entryScript(process).lowercased()
        let packages: [(String, String)] = [
            ("/@anthropic-ai/claude-code/", "claude"), ("/@openai/codex/", "codex"),
            ("/@google/gemini-cli/", "gemini"), ("/@github/copilot/", "copilot"),
            ("/@qwen-code/qwen-code/", "qwen"), ("/@mariozechner/pi-coding-agent/", "pi"),
        ]
        for (path, id) in packages where script.contains(path) {
            return Self.providers.first { $0.provider.id == id }?.provider
        }
        return nil
    }

    public func isDesktopAgent(_ process: ProcessRecord) -> Bool {
        desktopProvider(for: process) != nil
    }

    private func desktopProvider(for process: ProcessRecord) -> AgentProvider? {
        let path = process.executable.lowercased()
        if path.hasSuffix("/claude.app/contents/macos/claude") {
            return AgentProvider(id: "claude-desktop", name: "Claude", symbol: "asterisk")
        }
        if path.hasSuffix("/codex.app/contents/macos/codex") {
            return Self.providers.first { $0.provider.id == "codex" }?.provider
        }
        if path.hasSuffix("/cursor.app/contents/macos/cursor") || path.hasSuffix("/cursor.app/contents/macos/electron")
        {
            return Self.providers.first { $0.provider.id == "cursor" }?.provider
        }
        return nil
    }

    public func framework(for process: ProcessRecord) -> (name: String, isDevelopment: Bool) {
        let names = entryNames(process)
        let frameworks: [(Set<String>, String)] = [
            (["next", "next-server"], "Next.js"), (["vite"], "Vite"), (["astro"], "Astro"),
            (["wrangler"], "Wrangler"), (["storybook"], "Storybook"), (["nuxt", "nuxi"], "Nuxt"),
            (["uvicorn", "gunicorn", "fastapi"], "FastAPI"), (["flask"], "Flask"),
            (["rails"], "Rails"), (["http-server", "serve"], "Static server"),
        ]
        for (tokens, name) in frameworks where !tokens.isDisjoint(with: names) { return (name, true) }
        if process.arguments.contains("http.server") { return ("Python HTTP", true) }
        if process.arguments.contains("runserver") { return ("Django", true) }
        let runtimes: [(String, String)] = [
            ("node", "Node.js"), ("bun", "Bun"), ("deno", "Deno"), ("python", "Python"),
            ("ruby", "Ruby"), ("php", "PHP"), ("go", "Go"), ("cargo", "Rust"),
            ("java", "Java"), ("dotnet", ".NET"), ("postgres", "PostgreSQL"),
            ("redis-server", "Redis"), ("caddy", "Caddy"), ("nginx", "nginx"),
        ]
        for (token, label) in runtimes
        where names.contains(where: { $0 == token || (token == "python" && $0.hasPrefix("python3")) }) {
            return (label, true)
        }
        // Compiled project binaries can be development servers without a known runtime.
        if process.executable.contains("/target/debug/") || process.executable.contains("/go-build") {
            return (process.name, true)
        }
        return (process.name, false)
    }

    private func entryNames(_ process: ProcessRecord) -> Set<String> {
        let executable = URL(fileURLWithPath: process.executable).lastPathComponent.lowercased()
        var names: Set<String> = [executable]
        let script = entryScript(process)
        if !script.isEmpty {
            names.insert(URL(fileURLWithPath: script).deletingPathExtension().lastPathComponent.lowercased())
        }
        // Some frameworks replace argv[0] with a process title.
        if process.name.lowercased().hasPrefix("next-server") { names.insert("next-server") }
        return names
    }

    private func entryScript(_ process: ProcessRecord) -> String {
        let executable = URL(fileURLWithPath: process.executable).lastPathComponent.lowercased()
        let interpreters: Set<String> = [
            "node", "bun", "deno", "ruby", "python", "python3", "python3.11", "python3.12", "python3.13", "python3.14",
        ]
        guard interpreters.contains(executable) else { return "" }
        var arguments = Array(process.arguments.dropFirst())
        // Inline code is not an entry point; matching it would classify prompts as agents.
        if arguments.contains("-e") || arguments.contains("-c") || arguments.contains("--eval") { return "" }
        if let moduleIndex = arguments.firstIndex(of: "-m"), arguments.indices.contains(moduleIndex + 1) {
            return arguments[moduleIndex + 1]
        }
        if arguments.first == "run" { arguments.removeFirst() }
        return arguments.first(where: { !$0.hasPrefix("-") }) ?? ""
    }
}
