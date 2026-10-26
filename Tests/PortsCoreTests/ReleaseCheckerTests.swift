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
            Data(repeating: 0, count: 1_048_577),
        ] {
            #expect(throws: ReleaseCheckError.self) { try ReleaseChecker.parse(data, currentVersion: "1.0.0") }
        }
    }
}
