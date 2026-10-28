import PortsCore
import SwiftUI

struct PreferencesView: View {
    @Bindable var model: MonitorModel
    @State private var ruleName = ""
    @State private var executableName = ""
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                group("DETECTION") {
                    HStack {
                        settingLabel("Interval")
                        Spacer()
                        Picker("Interval", selection: $model.preferences.refreshInterval) {
                            ForEach([2, 3, 5, 10], id: \.self) { seconds in
                                Text("\(seconds) seconds").tag(Double(seconds))
                            }
                        }.labelsHidden().frame(width: 130).onChange(of: model.preferences.refreshInterval) {
                            model.savePreferences()
                        }
                    }
                    Divider().overlay(DS.line)
                    Toggle(isOn: Binding(get: { model.isMonitoring }, set: { model.setMonitoring($0) })) {
                        settingLabel("Automatic detection")
                    }.toggleStyle(.switch).controlSize(.small).tint(DS.accent)
                        .accessibilityLabel("Automatic detection")
                    Divider().overlay(DS.line)
                    Toggle(isOn: $model.preferences.showOtherListeners) {
                        settingLabel(
                            "Show all TCP listeners",
                            detail: "Also show services without a recognized development framework.")
                    }.toggleStyle(.switch).controlSize(.small).tint(DS.accent)
                        .accessibilityLabel("Show all TCP listeners").onChange(
                            of: model.preferences.showOtherListeners
                        ) { model.savePreferences() }
                    Divider().overlay(DS.line)
                    DisclosureGroup {
                        agentRules.padding(.top, 10)
                    } label: {
                        HStack {
                            Text("Custom agents")
                            Spacer()
                            if !model.preferences.agentRules.isEmpty {
                                Text(model.preferences.agentRules.count, format: .number).monospacedDigit()
                                    .foregroundStyle(DS.muted)
                            }
                        }.frame(minHeight: 40).contentShape(Rectangle())
                    }.font(.system(size: 12, weight: .medium)).tint(DS.muted)
                }
                group("ACCESS") {
                    loginItemRow
                    Divider().overlay(DS.line)
                    Toggle(isOn: $model.preferences.showNotch) {
                        settingLabel(
                            "Notch panel",
                            detail: "Opens \(AppInfo.name) at the top of the screen instead of in a window.")
                    }.toggleStyle(.switch).controlSize(.small).tint(DS.accent)
                        .accessibilityLabel("Notch panel").onChange(of: model.preferences.showNotch) {
                            model.savePreferences()
                            PanelWindowCoordinator.shared.configureNotch(model: model)
                        }
                    Divider().overlay(DS.line)
                    shortcutRow
                }
                group("TERMINAL") {
                    HStack {
                        settingLabel(
                            "Terminal app",
                            detail: "Opens a new window in the project folder. It can't attach to a running session.")
                        Picker("Terminal app", selection: $model.preferences.terminalApp) {
                            ForEach(terminalChoices, id: \.self) { terminal in terminalChoice(terminal) }
                        }.labelsHidden().fixedSize().onChange(of: model.preferences.terminalApp) {
                            model.savePreferences()
                        }
                    }
                }
                group("UPDATES") { updateControls }
                Divider().overlay(DS.line)
                footer
            }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
        }.scrollIndicators(.hidden)
            .onAppear {
                model.refreshInstalledTerminals()
                loginItem.refresh()
            }
            // The notch panel never activates the app and keeps this page mounted while collapsed, so neither
            // activation nor onAppear catches a change made in System Settings meanwhile.
            .onChange(of: model.isShowing(.notch)) { _, shown in if shown { loginItem.refresh() } }
    }

    private var loginItem: LoginItem { .shared }

    /// Reads the login item live and never saves it: System Settings can change it at any time.
    @ViewBuilder private var loginItemRow: some View {
        Toggle(isOn: Binding(get: { loginItem.isEnabled }, set: { setOpensAtLogin($0) })) {
            settingLabel("Open at login", detail: loginItemDetail)
        }.toggleStyle(.switch).controlSize(.small).tint(DS.accent)
            .accessibilityLabel("Open at login").accessibilityHint(Text(loginItemDetail))
            .disabled(!loginItem.isAvailable)
        if loginItem.requiresApproval {
            Button("Open Login Items…") { loginItem.openSystemSettings() }.buttonStyle(QuietButton())
        }
    }

    private var loginItemDetail: LocalizedStringResource {
        switch loginItem.availability {
        case .notBundled: "Only available in the installed app."
        case .needsMove: "Move the app to the Applications folder first."
        case .available where loginItem.requiresApproval: "Waiting for your approval in System Settings."
        case .available: "Starts quietly in the menu bar."
        }
    }

    private var shortcut: GlobalShortcut { .shared }

    /// It toggles the panel at home, so the copy names the app rather than the window: with the notch enabled, the
    /// notch opens.
    @ViewBuilder private var shortcutRow: some View {
        let detail: LocalizedStringResource = "Opens and closes \(AppInfo.name) from any app."
        Toggle(isOn: $model.preferences.opensWithGlobalShortcut) {
            settingLabel("Keyboard shortcut \(shortcut.display)", detail: detail)
        }.toggleStyle(.switch).controlSize(.small).tint(DS.accent)
            .accessibilityLabel("Keyboard shortcut \(shortcut.display)").accessibilityHint(Text(detail))
            .onChange(of: model.preferences.opensWithGlobalShortcut) {
                model.savePreferences()
                PanelWindowCoordinator.shared.configureShortcut(model: model)
            }
        if model.preferences.opensWithGlobalShortcut && shortcut.registrationFailed {
            Text("Already in use by another app.").font(.system(size: 11)).foregroundStyle(DS.orange)
        }
    }

    private func setOpensAtLogin(_ enabled: Bool) {
        do {
            try loginItem.setEnabled(enabled)
        } catch {
            model.report("The login item couldn't be changed.", as: .generic)
        }
    }

    /// The installed terminals, plus a saved one that is missing, so the picker shows what is saved.
    private var terminalChoices: [TerminalApp] {
        TerminalApp.allCases.filter { model.installedTerminals.contains($0) || $0 == model.preferences.terminalApp }
    }

    /// A missing terminal can't be chosen again; opening falls back to Terminal until it is installed.
    @ViewBuilder private func terminalChoice(_ terminal: TerminalApp) -> some View {
        if model.installedTerminals.contains(terminal) {
            Text(verbatim: terminal.displayName).tag(terminal)
        } else {
            Text("\(terminal.displayName) (not installed)").tag(terminal).disabled(true)
        }
    }

    @ViewBuilder private var updateControls: some View {
        let detail: LocalizedStringResource = "Asks GitHub for the latest version once a week. No identifiers are sent."
        Toggle(
            isOn: Binding(
                get: { model.preferences.checksForUpdatesAutomatically },
                set: { model.setAutomaticUpdateChecks($0) })
        ) {
            settingLabel("Check for updates weekly", detail: detail)
        }.toggleStyle(.switch).controlSize(.small).tint(DS.accent)
            .accessibilityLabel("Check for updates weekly").accessibilityHint(Text(detail))
        Divider().overlay(DS.line)
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            VStack(alignment: .leading, spacing: 6) {
                updateStatusLine
                if let checked = model.preferences.lastUpdateCheck {
                    // A clock that moved back would otherwise read as a check in the future.
                    Text("Last checked \(min(checked, Date()), format: .relative(presentation: .named))")
                        .foregroundStyle(DS.muted)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
            Button("Check Now") { Task { await model.runUpdateCheck(automatic: false) } }
                .buttonStyle(QuietButton()).disabled(model.updateCheckInFlight)
        }.font(.system(size: 11))
    }

    /// The release stays offered here after its hint was dismissed or a later check failed, so the gear's dot can
    /// always be dismissed; only dismissing takes the dot away.
    @ViewBuilder private var updateStatusLine: some View {
        if case .checking = model.updateStatus {
            Text("Checking…").foregroundStyle(DS.muted)
        } else {
            if isFailed { Text("The update check failed. Please try again later.").foregroundStyle(DS.muted) }
            if let release = model.latestAvailableRelease {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("Version \(release.version.string) is available.")
                    Link("Download ↗", destination: release.url).foregroundStyle(DS.accent)
                    if model.showsUpdateBadge {
                        Button("Dismiss") { model.dismissUpdateHint() }.buttonStyle(FooterLinkStyle())
                    }
                }
            } else if !isFailed, model.preferences.lastUpdateCheck != nil || isCurrent {
                // A failed check can't vouch for being up to date.
                Text("\(AppInfo.name) is up to date.").foregroundStyle(DS.muted)
            }
        }
    }

    private var isCurrent: Bool {
        if case .current = model.updateStatus { return true }
        return false
    }

    private var isFailed: Bool {
        if case .failed = model.updateStatus { return true }
        return false
    }

    /// Secondary destinations as quiet text, so they don't compete with the settings above.
    private var footer: some View {
        let demoTitle: LocalizedStringResource = model.demoMode ? "Live data" : "Demo"
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Button("Introduction") { model.presentOnboarding() }
                separator
                Button(demoTitle) { model.toggleDemo() }
                separator
                Link("Help ↗", destination: AppInfo.helpURL)
                separator
                Link("Privacy ↗", destination: AppInfo.privacyURL)
            }.buttonStyle(FooterLinkStyle())
            HStack {
                Text(verbatim: "\(AppInfo.name) \(AppInfo.version)").font(.system(size: 11)).foregroundStyle(DS.muted)
                Spacer()
                Button(
                    LocalizedStringResource(
                        "settings.quit", defaultValue: "Quit", comment: "Quits the app from the settings footer")
                ) { QuitCoordinator.shared.requestQuit() }.buttonStyle(QuietButton())
            }
        }
    }

    private var separator: some View {
        Text(verbatim: "·").font(.system(size: 11)).foregroundStyle(DS.muted).accessibilityHidden(true)
    }

    private var agentRules: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Exakter Dateiname oder Einstiegsskript, ohne Dateiendung.")
                .font(.system(size: 11)).foregroundStyle(DS.muted)
            ForEach(model.preferences.agentRules) { rule in
                HStack {
                    Text(rule.name).font(.system(size: 12))
                    Text(rule.executableName).font(.system(size: 10, design: .monospaced)).foregroundStyle(DS.muted)
                    Spacer()
                    IconButton(symbol: "minus.circle", help: "Regel entfernen") {
                        model.preferences.agentRules.removeAll { $0.id == rule.id }
                        model.savePreferences()
                        Task { await model.refresh() }
                    }
                }
            }
            HStack(spacing: 10) {
                TextField("Anzeigename", text: $ruleName).textFieldStyle(.roundedBorder)
                TextField("z. B. my-agent", text: $executableName).textFieldStyle(.roundedBorder)
                Button("Hinzufügen") {
                    model.preferences.agentRules.append(
                        AgentRule(
                            name: ruleName.trimmingCharacters(in: .whitespaces),
                            executableName: executableName.trimmingCharacters(in: .whitespaces).lowercased()))
                    ruleName = ""
                    executableName = ""
                    model.savePreferences()
                    Task { await model.refresh() }
                }.buttonStyle(QuietButton(tint: DS.accent))
                    .disabled(
                        ruleName.trimmingCharacters(in: .whitespaces).isEmpty
                            || executableName.trimmingCharacters(in: .whitespaces).isEmpty
                            || executableName.contains("/"))
            }.font(.system(size: 11))
        }
    }

    private func group<Content: View>(_ title: LocalizedStringResource, @ViewBuilder content: () -> Content)
        -> some View
    {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).overline()
            content()
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private func settingLabel(_ title: LocalizedStringResource, detail: LocalizedStringResource? = nil) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 12, weight: .medium))
            if let detail {
                Text(detail).font(.system(size: 11)).foregroundStyle(DS.muted)
                    .fixedSize(horizontal: false, vertical: true).lineSpacing(3)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Plain 11 pt text with a taller hit area than the glyphs.
private struct FooterLinkStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 11)).foregroundStyle(DS.muted)
            .opacity(configuration.isPressed ? 0.6 : 1)
            .padding(.vertical, 6).contentShape(Rectangle())
    }
}
