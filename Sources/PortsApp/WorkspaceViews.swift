import PortsCore
import SwiftUI

struct ProjectsView: View {
    @Bindable var model: MonitorModel
    let services: [ServiceRecord]
    private var groups: [(key: String, services: [ServiceRecord])] {
        Dictionary(grouping: services, by: \.projectKey)
            .map { (key: $0.key, services: $0.value) }
            .sorted {
                let first = model.preferences.favoriteProjects.contains($0.key)
                let second = model.preferences.favoriteProjects.contains($1.key)
                if first != second { return first }
                return $0.key.localizedStandardCompare($1.key) == .orderedAscending
            }
    }
    var body: some View {
        if groups.isEmpty {
            EmptyState(
                symbol: "folder", title: "Keine aktiven Projekte",
                detail: "Projekte erscheinen zusammen mit ihren Agenten und Servern.")
        } else {
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(groups, id: \.key) { group in
                        DisclosureGroup {
                            ForEach(group.services) { service in
                                Button {
                                    model.inspect(service)
                                } label: {
                                    HStack(spacing: 8) {
                                        ServiceIcon(service: service, size: 18)
                                        Text(service.title).font(.system(size: 12))
                                        Spacer()
                                        if let endpoint = service.primaryEndpoint {
                                            Text(verbatim: ":\(endpoint.port)").font(
                                                .system(size: 11, design: .monospaced)
                                            ).foregroundStyle(DS.muted)
                                        }
                                        StatusLabel(state: service.process.state, compact: true)
                                        Image(systemName: "chevron.right").font(.system(size: 9)).foregroundStyle(
                                            DS.muted)
                                    }.frame(height: 40).contentShape(Rectangle())
                                }.buttonStyle(.plain)
                            }
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: "folder").foregroundStyle(DS.muted)
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(group.services.first?.process.projectName ?? group.key).font(
                                        .system(size: 13, weight: .medium)
                                    ).lineLimit(1)
                                    Text(
                                        "\(group.services.count) \(group.services.count == 1 ? "Prozess" : "Prozesse")"
                                    ).font(.system(size: 11)).foregroundStyle(
                                        DS.muted)
                                }
                                Spacer()
                                IconButton(
                                    symbol: model.preferences.favoriteProjects.contains(group.key)
                                        ? "star.fill" : "star", help: "Projekt anheften"
                                ) {
                                    model.favorite(group.key)
                                }
                                if let directory = group.services.first?.process.workingDirectory {
                                    IconButton(symbol: "arrow.up.forward.square", help: "Projekt öffnen") {
                                        model.openDirectory(directory)
                                    }
                                    .disabled(model.demoMode)
                                }
                            }.frame(height: 64)
                        }.tint(DS.muted)
                        Rectangle().fill(DS.line).frame(height: 0.5)
                    }
                }.padding(.horizontal, 16)
            }
        }
    }
}
