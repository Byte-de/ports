import PortsCore
import PortsFeatures
import SwiftUI

/// The Servers or the Agents tab. It stays mounted while a page is pushed over it, so its list keeps the scroll
/// position.
struct ServicesPage: View {
    @Bindable var model: MonitorModel
    let surface: MonitorSurface
    let filter: ServiceFilter
    let services: [ServiceRecord]
    /// The surface's own search, which already filtered `services`.
    let search: String

    /// The rows and their share rows, within bounds: a short list keeps the panel compact, a long one scrolls.
    static func height(for services: [ServiceRecord], model: MonitorModel) -> CGFloat {
        let rows = services.reduce(CGFloat(8)) {
            $0 + DS.rowHeight + CGFloat(model.visibleTunnels(for: $1).count) * 48
        }
        return min(320, max(168, rows))
    }

    private var isPaused: Bool { !model.isMonitoring && !model.demoMode }

    var body: some View {
        if !model.hasScanned && !isPaused {
            VStack(spacing: 12) {
                ProgressView().controlSize(.small)
                Text("Detecting services…").font(.system(size: 11)).foregroundStyle(DS.muted)
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if services.isEmpty {
            emptyState
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(services) { service in
                        ServiceRow(model: model, service: service, surface: surface)
                        if service.id != services.last?.id {
                            Rectangle().fill(DS.line).frame(height: 0.5)
                        }
                    }
                }.padding(.horizontal, 16)
            }.scrollIndicators(.hidden)
        }
    }

    /// A search without results, then paused detection, explain an empty list before the tab's own hint does.
    @ViewBuilder private var emptyState: some View {
        if !search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            EmptyState(symbol: "magnifyingglass", title: "No matches", detail: "Search by project, name, PID or port.")
        } else if isPaused {
            VStack(spacing: 14) {
                EmptyState(
                    symbol: "pause.circle", title: "Detection paused",
                    detail: "New services appear once detection resumes.")
                Button("Resume") { model.setMonitoring(true) }.buttonStyle(QuietButton()).padding(.bottom, 28)
            }
        } else if filter == .agents {
            EmptyState(
                symbol: "sparkles", title: "No active agents",
                detail: "Supported agents appear automatically. Add your own in Settings.")
        } else {
            EmptyState(
                symbol: "server.rack", title: "No active servers",
                detail: "Start a dev server as usual or from Actions.")
        }
    }
}
