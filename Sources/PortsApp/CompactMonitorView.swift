import SwiftUI

struct CompactMonitorView: View {
    @Bindable var model: MonitorModel
    var body: some View {
        Group {
            if model.onboardingSession != nil {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Willkommen bei Byte Ports").font(.system(size: 14, weight: .medium))
                    Button("Einführung öffnen") { model.revealWindow?() }.buttonStyle(QuietButton())
                }.padding(20).frame(width: 310).foregroundStyle(DS.text).preferredColorScheme(.dark)
            } else {
                MonitorPanel(model: model, surface: .menu)
                    .padding(10)
            }
        }
        .background(PanelWindowRegistration(surface: .menu, model: model))
        .onAppear { PanelWindowCoordinator.shared.menuAppeared(model: model) }
    }
}
