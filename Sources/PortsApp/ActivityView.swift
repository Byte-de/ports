import SwiftUI

struct ActivityView: View {
    @Bindable var model: MonitorModel
    private var entries: [ActivityEntry] {
        model.activity.filter {
            model.search.isEmpty || $0.title.localizedCaseInsensitiveContains(model.search)
                || $0.detail.localizedCaseInsensitiveContains(model.search)
        }
    }
    var body: some View {
        if entries.isEmpty {
            EmptyState(
                symbol: "clock.arrow.circlepath", title: "Noch keine Ereignisse",
                detail: "Starts, beendete Prozesse und deine Aktionen erscheinen hier.")
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
