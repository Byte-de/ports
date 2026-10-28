import PortsCore
import PortsFeatures
import Testing

struct OnboardingChoicesTests {
    @Test func firstRunStartsWithTheOptInsOff() {
        let choices = OnboardingChoices(preferences: AppPreferences(), opensAtLogin: false)
        #expect(!choices.showNotch)
        #expect(!choices.launchAtLogin)
        #expect(!choices.checksForUpdatesAutomatically)
    }

    @Test func notchFollowsThePreference() {
        var preferences = AppPreferences()
        preferences.showNotch = true
        let choices = OnboardingChoices(preferences: preferences, opensAtLogin: false)
        #expect(choices.showNotch)
        #expect(!choices.launchAtLogin)
        #expect(!choices.checksForUpdatesAutomatically)
    }

    @Test func untouchedChoicesChangeNothing() {
        let original = AppPreferences()
        var preferences = original
        let choices = OnboardingChoices(preferences: original, opensAtLogin: false)
        choices.apply(to: &preferences)
        #expect(!preferences.checksForUpdatesAutomatically)
        #expect(preferences.showNotch == original.showNotch)
        #expect(choices.loginItemChange(currentlyEnabled: false) == nil)
    }

    @Test func switchedOnChoicesApply() {
        var preferences = AppPreferences()
        var choices = OnboardingChoices(preferences: preferences, opensAtLogin: false)
        choices.showNotch = true
        choices.launchAtLogin = true
        choices.checksForUpdatesAutomatically = true
        choices.apply(to: &preferences)
        #expect(preferences.showNotch)
        #expect(preferences.checksForUpdatesAutomatically)
        #expect(choices.loginItemChange(currentlyEnabled: false) == true)
        #expect(choices.loginItemChange(currentlyEnabled: true) == nil)
    }

    @Test func repeatedIntroductionKeepsEarlierOptIns() {
        var preferences = AppPreferences()
        preferences.checksForUpdatesAutomatically = true
        let choices = OnboardingChoices(preferences: preferences, opensAtLogin: true)
        #expect(choices.launchAtLogin)
        #expect(choices.checksForUpdatesAutomatically)
        choices.apply(to: &preferences)
        #expect(preferences.checksForUpdatesAutomatically)
        #expect(choices.loginItemChange(currentlyEnabled: true) == nil)
    }

    @Test func switchingOffInARepeatedIntroductionApplies() {
        var preferences = AppPreferences()
        preferences.checksForUpdatesAutomatically = true
        var choices = OnboardingChoices(preferences: preferences, opensAtLogin: true)
        choices.launchAtLogin = false
        choices.checksForUpdatesAutomatically = false
        choices.apply(to: &preferences)
        #expect(!preferences.checksForUpdatesAutomatically)
        #expect(choices.loginItemChange(currentlyEnabled: true) == false)
    }

    @Test func otherPreferencesStayUntouched() {
        var preferences = AppPreferences()
        preferences.opensWithGlobalShortcut = false
        preferences.detectsAutomatically = false
        preferences.refreshInterval = 10
        var choices = OnboardingChoices(preferences: preferences, opensAtLogin: false)
        choices.checksForUpdatesAutomatically = true
        choices.apply(to: &preferences)
        #expect(!preferences.opensWithGlobalShortcut)
        #expect(!preferences.detectsAutomatically)
        #expect(preferences.refreshInterval == 10)
        #expect(!preferences.hasCompletedOnboarding)
    }
}
