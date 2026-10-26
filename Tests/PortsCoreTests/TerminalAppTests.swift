import Testing

@testable import PortsCore

struct TerminalAppTests {
    @Test func rawValuesArePersistedNames() {
        #expect(TerminalApp.allCases.map(\.rawValue) == ["terminal", "iterm", "ghostty", "warp"])
    }

    @Test func bundleIdentifiersAreUnique() {
        let identifiers = TerminalApp.allCases.map(\.bundleIdentifier)
        #expect(Set(identifiers).count == identifiers.count)
        #expect(!identifiers.contains(""))
    }
}
