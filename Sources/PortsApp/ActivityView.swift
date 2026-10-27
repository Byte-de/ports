import SwiftUI

/// Pushed from the header's clock over any tab.
struct ActivityView: View {
    @Bindable var model: MonitorModel
    /// The surface's own search.
    let search: String
    private var entries: [ActivityEntry] {
        model.activity.filter {
            search.isEmpty || $0.title.localizedCaseInsensitiveContains(search)
                || $0.detail.localizedCaseInsensitiveContains(search)
        }
    }
    var body: some View {
        if entries.isEmpty {
            EmptyState(
                symbol: "clock.arrow.circlepath", title: "No activity yet",
                detail: "Detected and ended services and your actions appear here.")
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(entries) { entry in
                        HStack(spacing: 10) {
                            Image(systemName: entry.symbol).foregroundStyle(DS.muted).frame(width: 20)
                            VStack(alignment: .leading, spacing: 5) {
                                Text(entry.title).font(.system(size: 12)).lineLimit(1)
                                Text(entry.detail).font(.system(size: 11)).foregroundStyle(DS.muted).lineLimit(1)
                            }
                            Spacer()
                            Text(entry.date, style: .time).font(.system(size: 10, design: .monospaced)).foregroundStyle(
                                DS.muted)
                        }.frame(height: 64)
                        Rectangle().fill(DS.line).frame(height: 0.5)
                    }
                }.padding(.horizontal, 16)
            }
        }
    }
}
