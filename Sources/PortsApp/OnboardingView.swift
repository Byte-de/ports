import PortsCore
import PortsFeatures
import SwiftUI

private enum IntroductionStep: Int, CaseIterable, Sendable {
    case welcome, setup, ready

    var title: LocalizedStringResource {
        switch self {
        case .welcome: "Welcome"
        case .setup: "Set up"
        case .ready: "Ready"
        }
    }
    var previous: Self? { Self(rawValue: rawValue - 1) }
    var next: Self? { Self(rawValue: rawValue + 1) }
}

private enum IntroductionExit { case skip, live, demo }

/// Choices are a local draft. Navigating back or dismissing this view cannot
/// alter the app's preferences or start, stop or configure any agent process.
struct OnboardingView: View {
    @Bindable var model: MonitorModel
    @State private var step = IntroductionStep.welcome
    @State private var stepUsesMotion = false
    @State private var choices: OnboardingChoices
    @State private var completionError: String?
    @State private var requestedExit = IntroductionExit.live

    init(model: MonitorModel) {
        self.model = model
        _choices = State(
            initialValue: OnboardingChoices(preferences: model.preferences, opensAtLogin: LoginItem.shared.isEnabled))
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            DirectionalStage(
                selection: step, animated: stepUsesMotion, order: { $0.rawValue },
                distance: 32, duration: 0.24, exitFraction: 0.5
            ) { item in
                page(item)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            footer
        }
        .frame(width: 680, height: 536)
        .background(PanelGlass())
        .foregroundStyle(DS.text).preferredColorScheme(.dark)
        .panelAlert(
            title: "Settings couldn't be saved",
            message: completionError.map {
                $0 + "\n"
                    + String(
                        localized:
                            "Without saving, your choices apply to this session only. The existing file is kept.",
                        comment: "Onboarding save failure, explains Continue Without Saving")
            }
        ) {
            VStack(alignment: .trailing, spacing: 8) {
                Button("Try Again") { finish(requestedExit) }.buttonStyle(AccentButton())
                    .keyboardShortcut(.defaultAction)
                HStack {
                    Button("Continue Without Saving") { finish(requestedExit, persist: false) }
                        .buttonStyle(QuietButton())
                    Button("Back", role: .cancel) { completionError = nil }.buttonStyle(QuietButton())
                        .keyboardShortcut(.cancelAction)
                }
            }.frame(maxWidth: .infinity, alignment: .trailing)
        }
    }

    private var header: some View {
        ZStack(alignment: .trailing) {
            HStack(spacing: 12) {
                IconButton(symbol: "chevron.left", help: "Previous step") {
                    if let previous = step.previous { go(to: previous) }
                }.disabled(step.previous == nil)
                Text("\(step.rawValue + 1) of \(IntroductionStep.allCases.count)")
                    .font(.system(size: 10, weight: .medium)).monospacedDigit().foregroundStyle(DS.muted)
                Spacer(minLength: 8)
                HStack(spacing: 4) {
                    ForEach(IntroductionStep.allCases, id: \.self) { item in
                        Capsule().fill(item.rawValue <= step.rawValue ? DS.accent : .white.opacity(0.15))
                            .frame(width: 31, height: 3)
                    }
                }.accessibilityHidden(true)
                Spacer(minLength: 8)
                Text(step.title).font(.system(size: 11, weight: .medium)).frame(width: 86, alignment: .trailing)
            }
            .padding(.leading, 4).padding(.trailing, 18).frame(width: 430, height: 48)
            .background(
                .black.opacity(0.6), in: UnevenRoundedRectangle(bottomLeadingRadius: 18, bottomTrailingRadius: 18)
            )
            .frame(maxWidth: .infinity)
            Button {
                model.dismissOnboarding()
            } label: {
                Image(systemName: "xmark").font(.system(size: 12)).foregroundStyle(DS.muted)
                    .frame(width: 40, height: 40).contentShape(Rectangle())
            }
            .buttonStyle(.plain).help("Close introduction (Esc)")
            .accessibilityLabel("Close introduction").keyboardShortcut(.cancelAction)
            .padding(.trailing, 10)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(
            Text("Step \(step.rawValue + 1) of \(IntroductionStep.allCases.count): \(String(localized: step.title))"))
    }

    @ViewBuilder private func page(_ item: IntroductionStep) -> some View {
        switch item {
        case .welcome: welcome
        case .setup: setup
        case .ready: ready
        }
    }

    private var welcome: some View {
        VStack(spacing: 20) {
            VStack(spacing: 0) {
                // The icon already is the blue squircle with the mark, so it needs no tile of its own.
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 88, height: 88)
                    .accessibilityHidden(true).padding(.bottom, 14)
                Text("Welcome to \(AppInfo.name)").font(.system(size: 30, weight: .semibold)).tracking(-0.8)
                Text("Your agents and dev servers at a glance.")
                    .font(.system(size: 14)).foregroundStyle(DS.muted).multilineTextAlignment(.center)
                    .padding(.top, 6)
            }
            IntroductionPreview()
        }.padding(.horizontal, 32)
    }

    private var setup: some View {
        VStack(spacing: 18) {
            heading(
                "Always within reach.",
                detail: "\(AppInfo.name) lives in the menu bar. Its panel opens in a window or at the notch.")
            HStack(spacing: 14) {
                AccessChoice(notch: false, detail: windowDetail, selected: !choices.showNotch) {
                    choices.showNotch = false
                }
                AccessChoice(
                    notch: true, detail: "At the top center instead of a window.\nWorks on Macs without a notch.",
                    selected: choices.showNotch
                ) { choices.showNotch = true }
            }
            HStack(spacing: 0) {
                // A copy run with `swift run` or from the disk image can't register itself.
                if LoginItem.shared.isAvailable {
                    OptInToggle(
                        title: "Open at login", detail: "Starts quietly in the menu bar.",
                        isOn: $choices.launchAtLogin)
                    Rectangle().fill(DS.line).frame(width: 0.5).padding(.vertical, 12)
                }
                OptInToggle(
                    title: "Check for updates weekly", detail: "Asks GitHub once a week. Nothing else is sent.",
                    isOn: $choices.checksForUpdatesAutomatically)
            }
            // The divider would otherwise take all the height the step has, and the box with it.
            .fixedSize(horizontal: false, vertical: true)
            .background(.white.opacity(0.03), in: RoundedRectangle(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(DS.line))
        }.padding(.horizontal, 46)
    }

    /// Names the shortcut only while it is on, since a repeated introduction may find it switched off.
    private var windowDetail: LocalizedStringResource {
        guard model.preferences.opensWithGlobalShortcut else { return "Click the icon at the top right." }
        return "Click the icon at the top right.\n\(GlobalShortcut.shared.display) opens the window."
    }

    private var ready: some View {
        VStack(spacing: 20) {
            Image(systemName: "checkmark.circle").font(.system(size: 44, weight: .light)).foregroundStyle(DS.accent)
                .accessibilityHidden(true)
            heading("All set.", detail: "You'll find \(AppInfo.name) in the menu bar.")
            HStack(spacing: 10) {
                if model.demoMode {
                    Label("Live detection starts when you open \(AppInfo.name)", systemImage: "waveform.path")
                } else if !model.hasScanned {
                    ProgressView().controlSize(.small)
                    Text("Detecting services…")
                } else if model.counts.total == 0 {
                    Label("Ready for your first service", systemImage: "checkmark")
                } else {
                    let counts = model.counts
                    Label(
                        "\(counts.agents) \(counts.agents == 1 ? "Agent" : "Agenten")",
                        systemImage: "sparkles")
                    Text("·").foregroundStyle(DS.muted)
                    Label("\(counts.servers) Server erkannt", systemImage: "server.rack")
                }
            }.font(.system(size: 12)).monospacedDigit().foregroundStyle(DS.muted)
            if model.snapshot.warning != nil && !model.demoMode {
                Text("Some listeners can't be read right now. The panel has details.")
                    .font(.system(size: 11)).foregroundStyle(DS.orange)
            }
        }.padding(.horizontal, 32)
    }

    private func heading(_ title: LocalizedStringResource, detail: LocalizedStringResource) -> some View {
        VStack(spacing: 9) {
            Text(title).font(.system(size: 25, weight: .semibold)).tracking(-0.5)
            Text(detail).font(.system(size: 12)).foregroundStyle(DS.muted).multilineTextAlignment(.center).lineSpacing(
                3)
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if step != .ready {
                Button("Skip") { finish(.skip) }.buttonStyle(QuietButton(tint: DS.muted))
                    .help("Finish the introduction and keep your current settings")
            }
            Spacer()
            if step == .ready {
                Button("View Demo") { finish(.demo) }.buttonStyle(QuietButton())
                Button("Open \(AppInfo.name)") { finish(.live) }.buttonStyle(AccentButton()).keyboardShortcut(
                    .defaultAction)
            } else {
                Button {
                    if let next = step.next { go(to: next) }
                } label: {
                    HStack(spacing: 8) {
                        if step == .welcome { Text("Get Started") } else { Text("Continue") }
                        Image(systemName: "arrow.right").font(.system(size: 11))
                    }
                }.buttonStyle(AccentButton()).keyboardShortcut(.defaultAction)
            }
        }.padding(.horizontal, 28).padding(.bottom, 24).padding(.top, 8)
    }

    private func go(to step: IntroductionStep) {
        stepUsesMotion = PanelMotion.animatesInteraction
        self.step = step
    }

    private func finish(_ exit: IntroductionExit, persist: Bool = true) {
        requestedExit = exit
        completionError = nil
        do {
            try model.finishOnboarding(
                exit == .skip ? nil : choices, demo: exit == .skip ? nil : exit == .demo, persist: persist)
        } catch {
            completionError = error.localizedDescription
        }
    }
}

/// The panel in miniature with demo services: its tabs and quiet rows, which show their actions on hover only.
private struct IntroductionPreview: View {
    @State private var tab = PanelTab.servers
    private static let samples = DemoData.snapshot.services
    private var services: [ServiceRecord] {
        Array(Self.samples.filter { ($0.kind == .agent) == (tab == .agents) }.prefix(2))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Everything at a glance.").font(.system(size: 13, weight: .semibold))
            HStack(spacing: 4) {
                ForEach([PanelTab.servers, .agents], id: \.self) { item in
                    tabButton(item)
                }
            }
            VStack(spacing: 0) {
                ForEach(services) { service in
                    HStack(spacing: 8) {
                        ServiceIdentityLabel(service: service)
                        Text(verbatim: Format.uptime(service.id.startDate)).font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(DS.muted).monospacedDigit().lineLimit(1)
                    }.frame(height: 52)
                    if service.id != services.last?.id { Rectangle().fill(DS.line).frame(height: 0.5) }
                }
            }.padding(.horizontal, 16).padding(.vertical, 4).background(PanelGlass(radius: 20))
        }.frame(width: 480)
    }

    private func tabButton(_ item: PanelTab) -> some View {
        Button {
            tab = item
        } label: {
            Label(item.title, systemImage: item.symbol).font(.system(size: 11, weight: .medium))
                .padding(.horizontal, 12).frame(height: 32)
                .background(tab == item ? .white.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 10))
                .contentShape(RoundedRectangle(cornerRadius: 10))
        }.buttonStyle(.plain).foregroundStyle(tab == item ? DS.text : DS.muted)
            .accessibilityAddTraits(tab == item ? .isSelected : [])
    }
}

/// Where the panel opens. The notch panel replaces the window rather than adding to it.
private struct AccessChoice: View {
    let notch: Bool
    let detail: LocalizedStringResource
    let selected: Bool
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 12) {
                ZStack(alignment: .top) {
                    RoundedRectangle(cornerRadius: 12).fill(.black.opacity(0.22))
                    RoundedRectangle(cornerRadius: 12).strokeBorder(DS.line)
                    if notch {
                        UnevenRoundedRectangle(bottomLeadingRadius: 5, bottomTrailingRadius: 5).fill(.black)
                            .frame(width: 60, height: 12)
                        miniaturePanel.frame(width: 100, height: 46).padding(.top, 19)
                    } else {
                        HStack(spacing: 3) {
                            Circle().fill(DS.muted).frame(width: 3, height: 3)
                            Image(nsImage: DS.portGlyph).renderingMode(.template).resizable().frame(width: 7, height: 7)
                        }.foregroundStyle(DS.muted).frame(maxWidth: .infinity, alignment: .trailing).padding(7)
                        miniaturePanel.frame(width: 100, height: 46).padding(.top, 25)
                    }
                }.frame(height: 84).accessibilityHidden(true)
                HStack {
                    if notch { Text("Notch panel") } else { Text("Window") }
                    Spacer(minLength: 4)
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle").foregroundStyle(
                        selected ? DS.accent : DS.muted)
                }.font(.system(size: 13, weight: .medium))
                Text(detail).font(.system(size: 11)).foregroundStyle(DS.muted).lineSpacing(3)
                    .multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
            }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
                .background(selected ? .white.opacity(0.05) : .clear, in: RoundedRectangle(cornerRadius: 26))
                .overlay(
                    RoundedRectangle(cornerRadius: 26).strokeBorder(
                        selected ? DS.accent.opacity(0.6) : DS.line, lineWidth: 1)
                )
                .contentShape(RoundedRectangle(cornerRadius: 26))
        }.buttonStyle(.plain).accessibilityAddTraits(selected ? .isSelected : [])
            .accessibilityLabel(notch ? "Use the notch panel" : "Use a window").accessibilityHint(Text(detail))
    }
    private var miniaturePanel: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(0..<3) { _ in
                HStack(spacing: 5) {
                    RoundedRectangle(cornerRadius: 1).fill(DS.accent.opacity(0.65)).frame(width: 5, height: 5)
                    Capsule().fill(.white.opacity(0.3)).frame(height: 2)
                    Capsule().fill(.white.opacity(0.15)).frame(width: 15, height: 2)
                }
            }
        }.padding(9).background(.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.white.opacity(0.13)))
    }
}

/// An opt-in of the setup step. It starts as the setting is, which is off on a first run.
private struct OptInToggle: View {
    let title: LocalizedStringResource
    let detail: LocalizedStringResource
    @Binding var isOn: Bool
    var body: some View {
        Toggle(isOn: $isOn) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 12, weight: .medium))
                Text(detail).font(.system(size: 11)).foregroundStyle(DS.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }.frame(maxWidth: .infinity, alignment: .leading)
        }.toggleStyle(.switch).controlSize(.small).tint(DS.accent)
            .accessibilityLabel(Text(title)).accessibilityHint(Text(detail))
            .padding(.horizontal, 16).padding(.vertical, 12).frame(maxWidth: .infinity)
    }
}
