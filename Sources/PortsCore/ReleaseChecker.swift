import Foundation

/// Stable public versions only. Prereleases never replace an installed stable release.
public struct ReleaseVersion: Comparable, Sendable, Equatable {
    public let major: Int
    public let minor: Int
    public let patch: Int

    public init?(_ value: String) {
        let text = value.hasPrefix("v") ? String(value.dropFirst()) : value
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        let numbers = parts.compactMap { part -> Int? in
            guard !part.isEmpty, part.utf8.allSatisfy({ (48...57).contains($0) }),
                part.count == 1 || part.first != "0"
            else { return nil }
            return Int(part)
        }
        guard numbers.count == 3 else { return nil }
        (major, minor, patch) = (numbers[0], numbers[1], numbers[2])
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }
    public var string: String { "\(major).\(minor).\(patch)" }
}

public struct AvailableRelease: Sendable, Equatable {
    public let version: ReleaseVersion
    public let url: URL
}

public enum ReleaseCheckError: LocalizedError {
    case invalidResponse, unavailable
    public var errorDescription: String? {
        switch self {
        case .invalidResponse: "Die Update-Antwort konnte nicht geprüft werden. Bitte versuche es später erneut."
        case .unavailable: "Updates sind gerade nicht erreichbar. Bitte prüfe deine Verbindung und versuche es erneut."
        }
    }
}

public struct ReleaseChecker: Sendable {
    public init() {}

    /// No polling, installation, account, cookies, or telemetry. Called only by the user.
    public func check(currentVersion: String) async throws -> AvailableRelease? {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 20
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/Byte-de/ports/releases/latest")!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("Byte-Ports", forHTTPHeaderField: "User-Agent")
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
            http.url?.scheme == "https", http.url?.host == "api.github.com"
        else { throw ReleaseCheckError.unavailable }
        var data = Data()
        for try await byte in bytes {
            guard data.count < 1_048_576 else { throw ReleaseCheckError.invalidResponse }
            data.append(byte)
        }
        return try Self.parse(data, currentVersion: currentVersion)
    }

    public static func parse(_ data: Data, currentVersion: String) throws -> AvailableRelease? {
        struct Response: Decodable {
            let tagName: String
            let htmlURL: String
            let draft: Bool
            let prerelease: Bool
            private enum CodingKeys: String, CodingKey {
                case tagName = "tag_name"
                case htmlURL = "html_url"
                case draft, prerelease
            }
        }
        guard data.count <= 1_048_576, let current = ReleaseVersion(currentVersion),
            let response = try? JSONDecoder().decode(Response.self, from: data),
            let version = ReleaseVersion(response.tagName),
            response.tagName == "v\(version.string)", !response.draft, !response.prerelease,
            response.htmlURL == "https://github.com/Byte-de/ports/releases/tag/v\(version.string)",
            let url = URL(string: response.htmlURL)
        else { throw ReleaseCheckError.invalidResponse }
        return version > current ? AvailableRelease(version: version, url: url) : nil
    }
}
