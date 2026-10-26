import Foundation

/// The brand and version come from the bundle, so copy never hard-codes them.
/// Unbundled debug runs fall back to the product name.
enum AppInfo {
    static let name = Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "Byte Ports"
    static let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
}
