import Foundation

/// The brand and version come from the bundle, so copy never hard-codes them.
/// Unbundled debug runs fall back to the product name.
enum AppInfo {
    static let name = Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "Byte Ports"
    static let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
    static let helpURL = URL(string: "https://github.com/Byte-de/ports#readme")!
    /// Follows the language the app displays: the website's German notice, or its English one.
    static let privacyURL: URL = {
        let language = Bundle.main.preferredLocalizations.first.flatMap { Locale.Language(identifier: $0).languageCode }
        return language == Locale.LanguageCode.german
            ? URL(string: "https://ports.byte.de/datenschutz/")!
            : URL(string: "https://ports.byte.de/privacy/")!
    }()
}
