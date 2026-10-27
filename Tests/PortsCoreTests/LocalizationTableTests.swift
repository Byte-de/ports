import Foundation
import PortsCore
import Testing

/// The source tables in Resources/Localization. The test process has no app bundle, so Bundle.main has none.
enum LocalizationTable {
    static let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appending(path: "../../Resources/Localization").standardized

    static func bundle(_ language: String) -> Bundle? {
        Bundle(url: directory.appending(path: "\(language).lproj"))
    }

    /// Formats a key the way String(localized:) does in the packaged app running in `language`.
    static func format(_ key: String, language: String, _ arguments: any CVarArg...) -> String? {
        guard let bundle = bundle(language) else { return nil }
        let format = bundle.localizedString(forKey: key, value: nil, table: nil)
        return String(format: format, locale: Locale(identifier: language), arguments: arguments)
    }
}

struct LocalizationTableTests {
    @Test(arguments: ["de", "en"]) func tablesLoad(language: String) throws {
        let bundle = try #require(LocalizationTable.bundle(language))
        #expect(bundle.url(forResource: "Localizable", withExtension: "stringsdict") != nil)
        // English is the source text in code, so only German has a strings table.
        let strings = bundle.url(forResource: "Localizable", withExtension: "strings")
        #expect((strings != nil) == (language == "de"))
        if let strings {
            let table = try PropertyListSerialization.propertyList(from: Data(contentsOf: strings), format: nil)
            #expect(table is [String: String])
        }
    }

    @Test(arguments: [("de", 1, "1 Sekunde"), ("de", 2, "2 Sekunden"), ("en", 1, "1 second"), ("en", 10, "10 seconds")])
    func pluralRules(language: String, count: Int, expected: String) {
        #expect(LocalizationTable.format("%lld seconds", language: language, count) == expected)
    }

    @Test func sourceTextIsTheFallback() throws {
        let german = try #require(LocalizationTable.bundle("de"))
        #expect(german.localizedString(forKey: "Untranslated text", value: nil, table: nil) == "Untranslated text")
        // Without packaged tables the English source text is shown, plurals included.
        #expect(String(localized: "\(3) seconds") == "3 seconds")
    }

    /// The key of a formatted text is its format; the cases with an argument use the code 7.
    @Test(
        arguments: [
            (TunnelError.unsupportedServer, "Only running local HTTP development servers can be shared."),
            (
                TunnelError.notHTTP,
                "This service doesn't answer plain HTTP. Only local HTTP servers can be shared publicly."
            ),
            (TunnelError.serverChanged, "The server or its port is no longer active. Please try again."),
            (
                TunnelError.missingClient,
                "The Cloudflare client is missing from this installation. Please download and reinstall the app."
            ),
            (TunnelError.shuttingDown, "The app is quitting."),
            (TunnelError.couldNotStop, "Sharing has not stopped yet. Please stop it again."),
            (
                MonitorError.processChanged,
                "The process has already ended or its identity changed. The list will refresh."
            ),
            (MonitorError.protectedProcess, "This process is protected. Open its app to manage it there."),
            (MonitorError.signalFailed(7), "The action could not be completed (system error %d)."),
            (ReleaseCheckError.invalidResponse, "The update response could not be verified. Please try again later."),
            (
                ReleaseCheckError.unavailable,
                "Updates are not reachable right now. Check your connection and try again."
            ),
        ] as [(any LocalizedError & Sendable, String)])
    func coreErrorsHaveGermanText(error: any LocalizedError & Sendable, key: String) throws {
        #expect(error.errorDescription == String(format: key, Int32(7)))
        let german = try #require(LocalizationTable.bundle("de"))
        #expect(german.localizedString(forKey: key, value: nil, table: nil) != key)
    }
}
