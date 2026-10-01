import SwiftUI
import WidgetKit

struct UsageTimeline: TimelineProvider {
    func placeholder(in context: Context) -> UsageEntry { UsageEntry(date: Date(), snapshot: UsageSnapshot()) }
    func getSnapshot(in context: Context, completion: @escaping (UsageEntry) -> Void) {
        completion(UsageEntry(date: Date(), snapshot: SharedStore.load()))
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<UsageEntry>) -> Void) {
        let snapshot = SharedStore.load()
        let now = Date()
        // Scheduled entries update the age/reset labels without inventing quota recovery.
        let entries = stride(from: 0, through: 60, by: 5).map { minutes in
            UsageEntry(date: now.addingTimeInterval(Double(minutes) * 60), snapshot: snapshot)
        }
        completion(Timeline(entries: entries, policy: .after(now.addingTimeInterval(20 * 60))))
    }
}

@main
struct AIUsageWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: SharedStore.widgetKind, provider: UsageTimeline()) { entry in
            UsageWidgetView(entry: entry)
                .environment(\.locale, Locale(identifier: "ja_JP"))
                .containerBackground(.background, for: .widget)
        }
        .configurationDisplayName("AI Usage")
        .description("Codex・Claude Code・OpenCode Go・SuperGrokの定額枠の残りを確認。")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}
