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

    public init(version: ReleaseVersion) {
        self.version = version
        url = ReleaseChecker.releaseURL(for: version)
    }
}

public enum ReleaseCheckError: LocalizedError, Sendable {
    case invalidResponse, unavailable
    public var errorDescription: String? {
        switch self {
        case .invalidResponse:
            String(
                localized: "The update response could not be verified. Please try again later.",
                comment: "Update check error when GitHub's answer is malformed or unexpected")
        case .unavailable:
            String(
                localized: "Updates are not reachable right now. Check your connection and try again.",
                comment: "Update check error when GitHub could not be reached")
        }
    }
}

public struct ReleaseChecker: Sendable {
    static let repository = "Byte-de/ports"
    public static let responseLimit = 1_048_576
    private static let latestReleaseURL = URL(string: "https://api.github.com/repos/\(repository)/releases/latest")!
    private let configure: @Sendable (URLSessionConfiguration) -> Void

    public init(configure: @escaping @Sendable (URLSessionConfiguration) -> Void = { _ in }) {
        self.configure = configure
    }

    static func releaseURL(for version: ReleaseVersion) -> URL {
        URL(string: "https://github.com/\(repository)/releases/tag/v\(version.string)")!
    }

    /// No installation, account, cookies or telemetry. Runs when the user asks, or weekly after explicit opt-in.
    public func check(currentVersion: String) async throws -> AvailableRelease? {
        try await check(currentVersion: currentVersion, from: Self.latestReleaseURL)
    }

    // Tests pass their stub parameters in the endpoint's query.
    func check(currentVersion: String, from endpoint: URL) async throws -> AvailableRelease? {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 20
        configure(configuration)
        var request = URLRequest(url: endpoint)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("Byte-Ports", forHTTPHeaderField: "User-Agent")
        let release: AvailableRelease?
        do {
            let data = try await BoundedDownload.fetch(
                request, configuration: configuration, limit: Self.responseLimit, accept: Self.accepts)
            release = try Self.parse(data, currentVersion: currentVersion)
        } catch BoundedDownloadError.rejected {
            throw ReleaseCheckError.unavailable
        } catch let error as URLError {
            PortsLog.update.error("Update check failed: URLError \(error.code.rawValue, privacy: .public)")
            throw ReleaseCheckError.unavailable
        } catch BoundedDownloadError.tooLarge, ReleaseCheckError.invalidResponse {
            PortsLog.update.error("Update check failed: invalid response")
            throw ReleaseCheckError.invalidResponse
        }
        if let release {
            PortsLog.update.notice("Update available: \(release.version.string, privacy: .public)")
        } else {
            PortsLog.update.info("Update check: up to date (\(currentVersion, privacy: .public))")
        }
        return release
    }

    // Redirects are followed, so the final response must still come from the GitHub API over HTTPS.
    static func accepts(_ response: HTTPURLResponse) -> Bool {
        guard response.statusCode == 200, response.url?.scheme == "https", response.url?.host == "api.github.com"
        else {
            PortsLog.update.error("Update check failed: HTTP \(response.statusCode, privacy: .public)")
            return false
        }
        return true
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
        guard data.count <= responseLimit, let current = ReleaseVersion(currentVersion),
            let response = try? JSONDecoder().decode(Response.self, from: data),
            let version = ReleaseVersion(response.tagName),
            response.tagName == "v\(version.string)", !response.draft, !response.prerelease,
            response.htmlURL == releaseURL(for: version).absoluteString
        else { throw ReleaseCheckError.invalidResponse }
        return version > current ? AvailableRelease(version: version) : nil
    }
}
