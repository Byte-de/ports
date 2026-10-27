import PortsCore
import SwiftUI

struct ProjectsView: View {
    @Bindable var model: MonitorModel
    let services: [ServiceRecord]
    /// Project folders, favourites first, then one trailing group of services without a project.
    private var groups: [(key: String?, services: [ServiceRecord])] {
        let favorites = model.preferences.favoriteProjects
        return Dictionary(grouping: services, by: \.projectDirectory)
            .map { (key: $0.key, services: $0.value) }
            .sorted {
                guard let first = $0.key, let second = $1.key else { return $0.key != nil }
                if favorites.contains(first) != favorites.contains(second) { return favorites.contains(first) }
                return first.localizedStandardCompare(second) == .orderedAscending
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
                                    title(group.key).font(.system(size: 13, weight: .medium)).lineLimit(1)
                                    Text(
                                        "\(group.services.count) \(group.services.count == 1 ? "Prozess" : "Prozesse")"
                                    ).font(.system(size: 11)).foregroundStyle(
                                        DS.muted)
                                }
                                Spacer()
                                if let directory = group.key {
                                    IconButton(
                                        symbol: model.preferences.favoriteProjects.contains(directory)
                                            ? "star.fill" : "star", help: "Projekt anheften"
                                    ) {
                                        model.favorite(directory)
                                    }
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
    private func title(_ directory: String?) -> Text {
        guard let directory else { return Text("No project") }
        return Text(verbatim: URL(fileURLWithPath: directory).lastPathComponent)
    }
}
