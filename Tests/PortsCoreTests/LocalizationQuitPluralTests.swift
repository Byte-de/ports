import Testing

/// Plural rules of the quit panel.
struct LocalizationQuitPluralTests {
    static let stillRunning =
        "%lld services are still running 15 seconds after the stop request: %@. Force Quit ends the processes the app started, without cleanup; unsaved data may be lost."
    static let notResponding =
        "%lld processes didn't respond to Force Quit either. Check them in Activity Monitor. If you quit anyway, they keep running without the app."

    @Test(arguments: [
        ("de", 1, "+ 1 weiterer"), ("de", 3, "+ 3 weitere"), ("en", 1, "+ 1 more"), ("en", 3, "+ 3 more"),
    ])
    func servicesNotListed(language: String, count: Int, expected: String) {
        #expect(LocalizationTable.format("+ %lld more", language: language, count) == expected)
    }

    /// The verb agrees with the listed names; the count itself is not shown.
    @Test(arguments: [
        ("de", 1, "API", "API läuft 15 Sekunden nach der Stopp-Anfrage noch. Sofort beenden"),
        ("de", 2, "API und Web", "API und Web laufen 15 Sekunden nach der Stopp-Anfrage noch. Sofort beenden"),
        ("en", 1, "API", "API is still running 15 seconds after the stop request. Force Quit"),
        ("en", 2, "API and Web", "API and Web are still running 15 seconds after the stop request. Force Quit"),
    ])
    func unresponsiveServices(language: String, count: Int, names: String, expected: String) throws {
        let text = try #require(LocalizationTable.format(Self.stillRunning, language: language, count, names))
        #expect(text.hasPrefix(expected))
    }

    @Test(arguments: [
        ("de", 1, "API", "API konnte nicht beendet werden"),
        ("de", 2, "API und Web", "API und Web konnten nicht beendet werden"),
        ("en", 1, "API", "API couldn't be stopped"), ("en", 2, "API and Web", "API and Web couldn't be stopped"),
    ])
    func servicesNotStopped(language: String, count: Int, names: String, expected: String) {
        let key = "%lld services couldn't be stopped: %@"
        #expect(LocalizationTable.format(key, language: language, count, names) == expected)
    }

    @Test(arguments: [
        ("de", 1, "Der Prozess reagiert", "läuft er ohne sie weiter."),
        ("de", 2, "Die Prozesse reagieren", "laufen sie ohne die App weiter."),
        ("en", 1, "The process didn't", "it keeps running without the app."),
        ("en", 2, "The processes didn't", "they keep running without the app."),
    ])
    func processesNotStopped(language: String, count: Int, start: String, end: String) throws {
        let text = try #require(LocalizationTable.format(Self.notResponding, language: language, count))
        #expect(text.hasPrefix(start) && text.hasSuffix(end))
        #expect(!text.contains(String(count)))
    }
}
