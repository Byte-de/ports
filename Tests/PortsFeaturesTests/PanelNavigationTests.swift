import Foundation
import PortsCore
import PortsFeatures
import Testing

struct PanelNavigationTests {
    private let server = PanelDestination.details(ProcessIdentity(pid: 42, startSeconds: 100))
    private let output = PanelDestination.output(UUID())

    private func navigation(_ tab: PanelTab = .servers, pushing pages: [PanelDestination]) -> PanelNavigation {
        var navigation = PanelNavigation(tab: tab)
        for page in pages { navigation.push(page) }
        return navigation
    }

    @Test func threeTabsInBarOrderWithCommandDigits() {
        #expect(PanelTab.allCases == [.servers, .agents, .actions])
        #expect(PanelTab.allCases.map(\.keyEquivalent) == ["1", "2", "3"])
        #expect(PanelTab.allCases.map(\.keyEquivalent) == PanelTab.allCases.map { Character(String($0.rawValue + 1)) })
        #expect(PanelNavigation().tab == .servers)
    }

    @Test func serviceTabsReuseTheFilter() {
        #expect(PanelTab.allCases.map(\.serviceFilter) == [.servers, .agents, nil])
    }

    @Test func activityIsAPageNotATab() {
        var navigation = PanelNavigation(tab: .agents)
        navigation.push(.activity)
        #expect(navigation.tab == .agents)
        #expect(navigation.top == .activity)
        #expect(!navigation.isAtRoot)
    }

    @Test func backFromActivityReturnsToOrigin() {
        var fromTab = navigation(.agents, pushing: [.activity])
        fromTab.pop()
        #expect(fromTab == PanelNavigation(tab: .agents))
        var fromDetails = navigation(.servers, pushing: [server, .activity])
        fromDetails.pop()
        #expect(fromDetails.top == server)
        #expect(fromDetails.tab == .servers)

        var navigation = navigation(.agents, pushing: [.activity, .settings])
        navigation.pop()
        #expect(navigation.top == .activity)
        #expect(navigation.tab == .agents)
        navigation.pop()
        #expect(navigation.isAtRoot)
        #expect(navigation.top == nil)
        #expect(navigation.tab == .agents)
    }

    @Test func pushingOpenPageRevealsIt() {
        var navigation = navigation(pushing: [.activity, .settings, server])
        navigation.push(.settings)
        #expect(navigation.stack == [.activity, .settings])
        navigation.push(.settings)
        #expect(navigation.stack == [.activity, .settings])
        navigation.push(output)
        #expect(navigation.stack == [.activity, .settings, output])
    }

    @Test func selectingTabClearsStack() {
        var navigation = navigation(.servers, pushing: [server, .settings])
        navigation.select(.actions)
        #expect(navigation.tab == .actions)
        #expect(navigation.isAtRoot)
    }

    @Test func reselectingCurrentTabPopsToRoot() {
        var navigation = navigation(.agents, pushing: [.activity, server])
        navigation.select(.agents)
        #expect(navigation == PanelNavigation(tab: .agents))
    }

    @Test func popAtRootIsNoop() {
        var navigation = PanelNavigation(tab: .actions)
        navigation.pop()
        #expect(navigation == PanelNavigation(tab: .actions))
    }

    @Test func replaceTopOnlyWhenPushed() {
        var root = PanelNavigation(tab: .actions)
        root.replaceTop(with: output)
        #expect(root == PanelNavigation(tab: .actions))

        let restarted = PanelDestination.output(UUID())
        var pushed = navigation(.actions, pushing: [.settings, output])
        pushed.replaceTop(with: restarted)
        #expect(pushed.stack == [.settings, restarted])
        // A page further down is revealed rather than stacked twice.
        pushed.replaceTop(with: .settings)
        #expect(pushed.stack == [.settings])
    }
}
