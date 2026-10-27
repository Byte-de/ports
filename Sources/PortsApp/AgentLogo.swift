import AppKit

/// The agents' brand marks, bundled as SVG in Contents/Resources/AgentLogos and used with their owners' permission
/// (notices in ThirdParty/agent-logos.txt). Single-colour marks are templates, tinted like text on the dark panel;
/// the others keep their colours. Without the packaged app (`swift run`, tests) there are none, and rows fall back to
/// SF Symbols.
@MainActor
enum AgentLogo {
    private static let templates: Set<String> = [
        "aider", "cline", "codex", "copilot", "cursor", "droid", "goose", "hermes", "kilo",
    ]
    /// The desktop app and the CLI executable share the product's mark.
    private static let aliases = ["claude-desktop": "claude", "cursor-agent": "cursor"]
    private static var cache: [String: NSImage?] = [:]

    static func image(for providerID: String) -> NSImage? {
        let id = aliases[providerID] ?? providerID
        if let cached = cache[id] { return cached }
        let image = Bundle.main.url(forResource: id, withExtension: "svg", subdirectory: "AgentLogos")
            .flatMap(NSImage.init(contentsOf:))
        image?.isTemplate = templates.contains(id)
        cache[id] = image
        return image
    }
}
