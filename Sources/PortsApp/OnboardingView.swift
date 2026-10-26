import PortsCore
import SwiftUI

private enum IntroductionStep: Int, CaseIterable, Sendable {
    case welcome, preview, access, ready

    var title: LocalizedStringResource {
        switch self {
        case .welcome: "Willkommen"
        case .preview: "Das Panel"
        case .access: "Dein Zugriff"
        case .ready: "Bereit"
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
    @State private var showNotch: Bool
    @State private var completionError: String?
    @State private var requestedExit = IntroductionExit.live

    init(model: MonitorModel) {
        self.model = model
        _showNotch = State(initialValue: model.preferences.showNotch)
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
            title: "Einstellungen konnten nicht gespeichert werden",
            message: completionError.map {
                $0 + "\n"
                    + String(
                        localized:
                            "Ohne Speichern gilt deine Auswahl nur für diese Sitzung. Die vorhandene Datei bleibt erhalten."
                    )
            }
        ) {
            VStack(alignment: .trailing, spacing: 8) {
                Button("Erneut versuchen") { finish(requestedExit) }.buttonStyle(AccentButton())
                    .keyboardShortcut(.defaultAction)
                HStack {
                    Button("Ohne Speichern fortfahren") { finish(requestedExit, persist: false) }
                        .buttonStyle(QuietButton())
                    Button("Zurück", role: .cancel) { completionError = nil }.buttonStyle(QuietButton())
                        .keyboardShortcut(.cancelAction)
                }
            }.frame(maxWidth: .infinity, alignment: .trailing)
        }
    }

    private var header: some View {
        ZStack(alignment: .trailing) {
            HStack(spacing: 12) {
                IconButton(symbol: "chevron.left", help: "Vorheriger Schritt") {
                    if let previous = step.previous { go(to: previous) }
                }.disabled(step.previous == nil)
                Text("\(step.rawValue + 1) von \(IntroductionStep.allCases.count)")
                    .font(.system(size: 10, weight: .medium)).monospacedDigit().foregroundStyle(DS.muted)
                Spacer(minLength: 8)
                HStack(spacing: 4) {
                    ForEach(IntroductionStep.allCases, id: \.self) { item in
                        Capsule().fill(item.rawValue <= step.rawValue ? DS.accent : .white.opacity(0.15))
                            .frame(width: 23, height: 3)
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
            .buttonStyle(.plain).help("Einführung schließen (Esc)")
            .accessibilityLabel("Einführung schließen").keyboardShortcut(.cancelAction)
            .padding(.trailing, 10)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(
            Text(
                "Schritt \(step.rawValue + 1) von \(IntroductionStep.allCases.count): \(String(localized: step.title))"
            ))
    }

    @ViewBuilder private func page(_ item: IntroductionStep) -> some View {
        switch item {
        case .welcome: welcome
        case .preview: preview
        case .access: access
        case .ready: ready
        }
    }

    private var welcome: some View {
        VStack(spacing: 22) {
            ZStack {
                RoundedRectangle(cornerRadius: 22).fill(DS.accent.gradient)
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 76, height: 76)
                Circle().frame(width: 9, height: 9)
            }
            .foregroundStyle(DS.background).frame(width: 82, height: 82)
            .shadow(color: .black.opacity(0.2), radius: 12, y: 6).accessibilityHidden(true)
            VStack(spacing: 10) {
                Text("Willkommen bei Byte Ports").font(.system(size: 30, weight: .semibold)).tracking(-0.8)
                Text("Deine Agenten und Dev-Server im Blick.")
                    .font(.system(size: 14)).foregroundStyle(DS.muted).multilineTextAlignment(.center).lineSpacing(4)
            }
        }.padding(28)
    }

    private var preview: some View {
        VStack(spacing: 18) {
            heading("Ein Blick genügt.", detail: "Agenten und Server erscheinen automatisch im Panel.")
            IntroductionPreview()
        }.padding(.horizontal, 32)
    }

    private var access: some View {
        VStack(spacing: 23) {
            heading("Immer in Reichweite.", detail: "Wähle deinen Schnellzugriff.")
            HStack(spacing: 14) {
                AccessChoice(notch: false, selected: !showNotch) { showNotch = false }
                AccessChoice(notch: true, selected: showNotch) { showNotch = true }
            }.padding(.horizontal, 46)
        }
    }

    private var ready: some View {
        VStack(spacing: 20) {
            Image(systemName: "checkmark.circle").font(.system(size: 44, weight: .light)).foregroundStyle(DS.accent)
                .accessibilityHidden(true)
            heading(
                "Alles bereit.",
                detail: "Starte deine Agenten und Server wie gewohnt."
            )
            HStack(spacing: 10) {
                if model.demoMode {
                    Label("Live-Erkennung startet beim Öffnen", systemImage: "waveform.path")
                } else if !model.hasScanned {
                    ProgressView().controlSize(.small)
                    Text("Laufende Prozesse werden erfasst…")
                } else if model.counts.total == 0 {
                    Label("Bereit für deinen ersten Dienst", systemImage: "checkmark")
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
                Text("Ein Teil der Listener ist gerade nicht lesbar. Details findest du im Panel.")
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
                Button("Überspringen") { finish(.skip) }.buttonStyle(QuietButton(tint: DS.muted))
                    .help("Einführung abschließen und bisherige Einstellungen beibehalten")
            }
            Spacer()
            if step == .ready {
                Button("Demo ansehen") { finish(.demo) }.buttonStyle(QuietButton())
                Button("Byte Ports öffnen") { finish(.live) }.buttonStyle(AccentButton()).keyboardShortcut(
                    .defaultAction)
            } else {
                Button {
                    if let next = step.next { go(to: next) }
                } label: {
                    HStack(spacing: 8) {
                        Text(step == .welcome ? "Los geht’s" : "Weiter")
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
                showNotch: exit == .skip ? nil : showNotch,
                demo: exit == .skip ? nil : exit == .demo, persist: persist)
        } catch {
            completionError = error.localizedDescription
        }
    }
}

private struct IntroductionPreview: View {
    @State private var agents = false
    private static let samples = DemoData.snapshot.services
    private var services: [ServiceRecord] { Array(Self.samples.filter { ($0.kind == .agent) == agents }.prefix(2)) }

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 4) {
                tab("Server", symbol: "server.rack", selected: !agents) { agents = false }
                tab("Agenten", symbol: "sparkles", selected: agents) { agents = true }
                Spacer()
            }
            VStack(spacing: 0) {
                ForEach(services) { service in
                    HStack(spacing: 8) {
                        ServiceIdentityLabel(service: service)
                        Text(Format.uptime(service.id.startDate)).font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(DS.muted)
                        actionIcon("arrow.up.forward.square", title: "Öffnen")
                        actionIcon("doc.on.doc", title: agents ? "PID kopieren" : "URL kopieren")
                        actionIcon("stop.circle", title: "Stoppen", tint: DS.red)
                    }.frame(height: DS.rowHeight)
                    if service.id != services.last?.id { Rectangle().fill(DS.line).frame(height: 0.5) }
                }
            }.padding(.horizontal, 16).padding(.vertical, 4).background(PanelGlass(radius: 20))
        }.frame(width: 480)
    }
    private func actionIcon(_ symbol: String, title: LocalizedStringResource, tint: Color = DS.muted) -> some View {
        Image(systemName: symbol).font(.system(size: 13)).foregroundStyle(tint)
            .frame(width: 24, height: 40).help(Text(title)).accessibilityLabel(Text(title))
    }
    private func tab(
        _ title: LocalizedStringResource, symbol: String, selected: Bool, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol).font(.system(size: 11, weight: .medium))
                .padding(.horizontal, 12).frame(height: 40)
                .background(selected ? .white.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 10))
        }.buttonStyle(.plain).foregroundStyle(selected ? DS.text : DS.muted).accessibilityAddTraits(
            selected ? .isSelected : [])
    }
}

private struct AccessChoice: View {
    let notch: Bool
    let selected: Bool
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 14) {
                ZStack(alignment: .top) {
                    RoundedRectangle(cornerRadius: 12).fill(.black.opacity(0.22))
                    RoundedRectangle(cornerRadius: 12).strokeBorder(DS.line)
                    if notch {
                        UnevenRoundedRectangle(bottomLeadingRadius: 5, bottomTrailingRadius: 5).fill(.black)
                            .frame(width: 65, height: 14)
                        miniaturePanel.frame(width: 106, height: 49).padding(.top, 21)
                    } else {
                        HStack(spacing: 3) {
                            Circle().fill(DS.muted).frame(width: 3, height: 3)
                            Image(systemName: "point.3.connected.trianglepath.dotted").font(.system(size: 6))
                        }.foregroundStyle(DS.muted).frame(maxWidth: .infinity, alignment: .trailing).padding(8)
                        miniaturePanel.frame(width: 110, height: 53).padding(.top, 29)
                    }
                }.frame(height: 105).accessibilityHidden(true)
                HStack {
                    Text(notch ? "Mit Notch-Panel" : "Fenster & Menüleiste").font(.system(size: 13, weight: .medium))
                    Spacer(minLength: 4)
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle").foregroundStyle(
                        selected ? DS.accent : DS.muted)
                }
                Text(
                    notch
                        ? "Am oberen Bildschirmrand.\nAuch auf Macs ohne Notch."
                        : "Ein kompaktes Fenster.\nFrei auf dem Bildschirm platzierbar."
                )
                .font(.system(size: 11)).foregroundStyle(DS.muted).lineSpacing(3).multilineTextAlignment(.leading)
            }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
                .background(selected ? .white.opacity(0.05) : .clear, in: RoundedRectangle(cornerRadius: 26))
                .overlay(
                    RoundedRectangle(cornerRadius: 26).strokeBorder(
                        selected ? DS.accent.opacity(0.6) : DS.line, lineWidth: 1)
                )
                .contentShape(RoundedRectangle(cornerRadius: 26))
        }.buttonStyle(.plain).accessibilityAddTraits(selected ? .isSelected : [])
            .accessibilityLabel(notch ? "Notch-Panel zusätzlich verwenden" : "Fenster und Menüleiste verwenden")
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
