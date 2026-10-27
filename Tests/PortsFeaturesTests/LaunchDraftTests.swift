import Foundation
import PortsCore
import PortsFeatures
import Testing

struct LaunchDraftTests {
    /// Every test makes its folders here and removes them when it ends.
    private let root = FileManager.default.temporaryDirectory.appending(path: "launch-draft-\(UUID().uuidString)")

    private func folder(_ name: String) throws -> String {
        let url = root.appending(path: name, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url.path
    }

    @Test func prefillPrefersExplicitThenInspectedThenLast() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let explicit = try folder("explicit")
        let inspected = try folder("inspected")
        let last = try folder("last")
        let vite = service(.server, pid: 1, title: "Vite", directory: inspected, ports: [5173])
        let agent = service(.agent, pid: 2, title: "Claude")

        #expect(
            LaunchDraft.prefill(explicit: LaunchDraft(directory: explicit), inspected: vite, lastDirectory: last)
                .directory == explicit)
        // A draft that names no folder still gets one.
        #expect(LaunchDraft.prefill(explicit: LaunchDraft(name: "Web"), inspected: vite).directory == inspected)
        #expect(LaunchDraft.prefill(inspected: vite, lastDirectory: last).directory == inspected)
        #expect(LaunchDraft.prefill(inspected: agent, lastDirectory: last).directory == last)
        #expect(LaunchDraft.prefill(lastDirectory: last).directory == last)
        #expect(LaunchDraft.prefill() == LaunchDraft())
    }

    @Test func prefillIgnoresRootAndMissingDirectories() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let last = try folder("last")
        let file = root.appending(path: "notes.txt")
        try Data().write(to: file)
        let missing = root.appending(path: "moved").path

        #expect(LaunchDraft.projectDirectory(of: nil) == nil)
        #expect(LaunchDraft.projectDirectory(of: "/") == nil)
        #expect(LaunchDraft.projectDirectory(of: "//") == nil)
        #expect(LaunchDraft.projectDirectory(of: "relative") == nil)
        #expect(LaunchDraft.projectDirectory(of: missing) == nil)
        #expect(LaunchDraft.projectDirectory(of: file.path) == nil)
        #expect(LaunchDraft.projectDirectory(of: last) == last)

        #expect(LaunchDraft.prefill(lastDirectory: "/") == LaunchDraft())
        #expect(LaunchDraft.prefill(lastDirectory: missing) == LaunchDraft())
        #expect(LaunchDraft.prefill(lastDirectory: file.path) == LaunchDraft())
        let gone = service(.server, pid: 1, title: "Vite", directory: missing, ports: [5173])
        #expect(LaunchDraft.prefill(inspected: gone, lastDirectory: last).directory == last)
        // What the user asked for stays, so the form reports the missing folder instead of swapping in another.
        #expect(
            LaunchDraft.prefill(explicit: LaunchDraft(directory: missing), lastDirectory: last).directory == missing)
    }

    @Test func suggestedNameIsFolderName() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let site = try folder("My Site")
        let vite = service(.server, pid: 1, title: "Vite", directory: site, ports: [5173])

        #expect(LaunchDraft.prefill(lastDirectory: site).suggestedName == "My Site")
        #expect(LaunchDraft.prefill(inspected: vite).suggestedName == "My Site")
        #expect(LaunchDraft.prefill(explicit: LaunchDraft(directory: site)).suggestedName == "My Site")
        #expect(
            LaunchDraft.prefill(explicit: LaunchDraft(directory: site, suggestedName: "Web")).suggestedName == "Web")
        #expect(LaunchDraft.prefill(lastDirectory: "/").suggestedName == nil)
    }
}
