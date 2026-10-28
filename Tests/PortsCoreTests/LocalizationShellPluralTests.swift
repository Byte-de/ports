import Testing

/// Plural rules of the onboarding, settings and app shell.
struct LocalizationShellPluralTests {
    @Test(arguments: [
        ("de", 1, "1 Agent"), ("de", 2, "2 Agenten"), ("en", 1, "1 agent"), ("en", 2, "2 agents"),
    ])
    func detectedAgents(language: String, count: Int, expected: String) {
        #expect(LocalizationTable.format("%lld agents", language: language, count) == expected)
    }

    @Test(arguments: [
        ("de", 1, "1 Server erkannt"), ("de", 2, "2 Server erkannt"), ("en", 1, "1 server detected"),
        ("en", 2, "2 servers detected"),
    ])
    func detectedServers(language: String, count: Int, expected: String) {
        #expect(LocalizationTable.format("%lld servers detected", language: language, count) == expected)
    }
}
