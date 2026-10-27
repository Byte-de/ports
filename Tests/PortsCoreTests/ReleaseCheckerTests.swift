import Foundation
import Testing

@testable import PortsCore

struct ReleaseCheckerTests {
    private func response(_ version: String, url: String? = nil, draft: Bool = false, prerelease: Bool = false) -> Data
    {
        try! JSONSerialization.data(withJSONObject: [
            "tag_name": version,
            "html_url": url ?? "https://github.com/Byte-de/ports/releases/tag/\(version)",
            "draft": draft, "prerelease": prerelease,
        ])
    }

    @Test func comparesNumericComponentsAndDoesNotOfferDowngrades() throws {
        #expect(try ReleaseChecker.parse(response("v1.0.0"), currentVersion: "1.0.0") == nil)
        #expect(try ReleaseChecker.parse(response("v1.0.0"), currentVersion: "1.1.0") == nil)
        #expect(try ReleaseChecker.parse(response("v1.10.0"), currentVersion: "1.9.0")?.version.string == "1.10.0")
        #expect(try ReleaseChecker.parse(response("v2.0.0"), currentVersion: "1.99.99")?.version.string == "2.0.0")
    }

    @Test(arguments: ["", "1.0", "v01.0.0", "1.0.0-beta.1", "1.0.0+123", "-1.0.0", "1.0.0.1", " 1.0.0", "１.0.0"])
    func rejectsAmbiguousVersions(value: String) {
        #expect(ReleaseVersion(value) == nil)
    }

    @Test(arguments: [
        "http://github.com/Byte-de/ports/releases/tag/v1.1.0",
        "https://github.com.evil.test/Byte-de/ports/releases/tag/v1.1.0",
        "https://github.com/another/app/releases/tag/v1.1.0",
        "https://github.com/Byte-de/ports/releases/tag/v1.1.0?redirect=evil",
    ])
    func rejectsUntrustedDownloads(url: String) {
        #expect(throws: ReleaseCheckError.self) {
            try ReleaseChecker.parse(response("v1.1.0", url: url), currentVersion: "1.0.0")
        }
    }

    @Test func rejectsDraftPrereleaseCorruptAndOversizedResponses() {
        for data in [
            response("v1.1.0", draft: true), response("v1.1.0", prerelease: true), Data("{}".utf8),
            Data(repeating: 0, count: ReleaseChecker.responseLimit + 1),
        ] {
            #expect(throws: ReleaseCheckError.self) { try ReleaseChecker.parse(data, currentVersion: "1.0.0") }
        }
    }

    private static let limit = ReleaseChecker.responseLimit

    private func download(_ query: String) async throws -> Data {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        return try await BoundedDownload.fetch(
            URLRequest(url: StubProtocol.url(query)), configuration: configuration, limit: Self.limit,
            accept: ReleaseChecker.accepts)
    }

    private func check(_ query: String) async throws -> AvailableRelease? {
        try await ReleaseChecker { $0.protocolClasses = [StubProtocol.self] }
            .check(currentVersion: "1.0.0", from: StubProtocol.url(query))
    }

    @Test func acceptsBodyAtLimit() async throws {
        #expect(try await download("size=\(Self.limit)").count == Self.limit)
        #expect(try await download("size=\(Self.limit)&length=\(Self.limit)").count == Self.limit)
    }

    @Test func rejectsOversizedWithoutContentLength() async {
        await #expect(throws: BoundedDownloadError.tooLarge) { try await download("size=\(Self.limit + 1)") }
        await #expect(throws: ReleaseCheckError.invalidResponse) { try await check("size=\(Self.limit + 1)") }
    }

    @Test func rejectsOversizedContentLengthBeforeBody() async {
        // The body itself is tiny, so only the declared length can trigger the rejection.
        await #expect(throws: BoundedDownloadError.tooLarge) { try await download("size=16&length=\(Self.limit + 1)") }
        await #expect(throws: ReleaseCheckError.invalidResponse) {
            try await check("json=v9.9.9&length=\(Self.limit + 1)")
        }
    }

    @Test func rejectsNon200() async {
        await #expect(throws: BoundedDownloadError.rejected) { try await download("status=404&size=16") }
        await #expect(throws: ReleaseCheckError.unavailable) { try await check("json=v9.9.9&status=500") }
    }

    @Test func rejectsResponseFromOtherHost() async {
        await #expect(throws: ReleaseCheckError.unavailable) {
            try await check("json=v9.9.9&host=github.com.evil.test")
        }
    }

    @Test func parsesStubbedRelease() async throws {
        let release = try #require(try await check("json=v9.9.9"))
        #expect(release.version.string == "9.9.9")
        #expect(release.url.absoluteString == "https://github.com/Byte-de/ports/releases/tag/v9.9.9")
        #expect(release == AvailableRelease(version: try #require(ReleaseVersion("9.9.9"))))
    }
}

/// Answers from its URL's query alone, so parallel tests share no state: `size` bytes of body (or a release JSON for
/// `json`'s tag), the `status` code, a declared Content-Length of `length` and a response URL on `host`.
private final class StubProtocol: URLProtocol {
    static func url(_ query: String) -> URL { URL(string: "https://api.github.com/stub?\(query)")! }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        guard let url = request.url, var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return client!.urlProtocol(self, didFailWithError: URLError(.badURL))
        }
        var query: [String: String] = [:]
        for item in components.queryItems ?? [] { query[item.name] = item.value }
        var body = Data(repeating: 0x20, count: query["size"].flatMap { Int($0) } ?? 0)
        if let tag = query["json"] {
            body = try! JSONSerialization.data(withJSONObject: [
                "tag_name": tag, "html_url": "https://github.com/Byte-de/ports/releases/tag/\(tag)",
                "draft": false, "prerelease": false,
            ])
        }
        if let host = query["host"] { components.host = host }
        let response = HTTPURLResponse(
            url: components.url!, statusCode: query["status"].flatMap { Int($0) } ?? 200, httpVersion: "HTTP/1.1",
            headerFields: query["length"].map { ["Content-Length": $0] })!
        client!.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        var offset = 0
        while offset < body.count {
            let end = min(offset + 16_384, body.count)
            client!.urlProtocol(self, didLoad: body.subdata(in: offset..<end))
            offset = end
        }
        client!.urlProtocolDidFinishLoading(self)
    }
}
