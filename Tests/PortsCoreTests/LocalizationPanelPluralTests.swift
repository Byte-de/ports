import Testing

/// Plural rules of the panel, its services and their details.
struct LocalizationPanelPluralTests {
    @Test(arguments: [
        ("de", 1, "CPU-Verlauf aus 1 Messung"), ("de", 2, "CPU-Verlauf aus 2 Messungen"),
        ("en", 1, "CPU history from 1 sample"), ("en", 2, "CPU history from 2 samples"),
    ])
    func cpuHistory(language: String, count: Int, expected: String) {
        #expect(LocalizationTable.format("CPU history from %lld samples", language: language, count) == expected)
    }
}
