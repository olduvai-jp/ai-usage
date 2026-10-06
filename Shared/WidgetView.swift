import SwiftUI
import WidgetKit

struct UsageEntry: TimelineEntry {
    let date: Date
    let snapshot: UsageSnapshot
}

struct UsageWidgetView: View {
    let entry: UsageEntry
    var previewFamily: WidgetFamily? = nil
    @Environment(\.widgetFamily) private var widgetFamily
    private var family: WidgetFamily { previewFamily ?? widgetFamily }
    private var services: [ServiceUsage] { entry.snapshot.configuredServices }

    var body: some View {
        VStack(alignment: .leading, spacing: services.count > 3 ? 4 : family == .systemLarge ? 12 : 8) {
            HStack {
                Text("残り").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                if family != .systemSmall {
                    Button(intent: RefreshUsageIntent()) { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(.plain).accessibilityLabel("使用状況を更新")
                }
            }
            if let error = entry.snapshot.loadError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
            } else if services.isEmpty {
                Link("接続設定を開く", destination: URL(string: "macaiusage://settings")!)
                    .font(.caption)
            }
            ForEach(services) { usage in
                if family == .systemSmall {
                    CompactUsageRow(usage: usage, now: entry.date)
                } else {
                    Link(destination: usage.service.detailURL) {
                        if family == .systemLarge { largeRow(usage) }
                        else { mediumRow(usage) }
                    }.buttonStyle(.plain)
                }
                if family == .systemLarge && usage.id != services.last?.id { Divider() }
            }
            Spacer(minLength: 0)
            footer
        }
        .widgetURL(URL(string: "macaiusage://overview")!)
    }

    private func mediumRow(_ usage: ServiceUsage) -> some View {
        HStack(spacing: 8) {
            ServiceIcon(service: usage.service, size: 19)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(usage.service.name).font(.system(size: 11, weight: .medium))
                    UsageWarning(usage: usage, now: entry.date)
                }
                Text((usage.window(.short) ?? (usage.service == .grok ? usage.commonWindows.first : nil))?.resetText(at: entry.date) ?? usage.state.label)
                    .font(.system(size: 9)).foregroundStyle(.secondary)
            }.frame(width: 92, alignment: .leading)
            Spacer(minLength: 0)
            if usage.windows.isEmpty { Text("—").foregroundStyle(.secondary) }
            ForEach(usage.commonWindows) { window in
                RemainingValue(window: window, compact: true).font(.system(size: 11))
            }
        }.lineLimit(1).minimumScaleFactor(0.8)
    }

    private func largeRow(_ usage: ServiceUsage) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                ServiceIcon(service: usage.service, size: 18)
                Text(usage.service.name).font(.subheadline.weight(.semibold))
                UsageWarning(usage: usage, now: entry.date)
                Spacer()
                Text(usage.state == .ready ? usage.ageText(at: entry.date) : usage.state.label)
                    .font(.system(size: 9)).foregroundStyle(.secondary)
            }
            if usage.commonWindows.isEmpty {
                Text(usage.state.label).font(.caption).foregroundStyle(.secondary)
            }
            ForEach(usage.commonWindows) { window in
                HStack(spacing: 7) {
                    Text(window.kind.abbreviation).font(.caption2).foregroundStyle(.secondary)
                    QuotaBar(remaining: window.remaining).frame(maxWidth: 80)
                    Text(window.remainingText).font(.caption.monospacedDigit().weight(.semibold))
                        .foregroundStyle(quotaColor(window.remaining)).frame(width: 36, alignment: .trailing)
                    Spacer(minLength: 0)
                    Text(window.resetText(at: entry.date)).font(.system(size: 9)).foregroundStyle(.secondary)
                }.lineLimit(1).minimumScaleFactor(0.8)
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 3) {
            if services.contains(where: { $0.state == .failed || $0.state == .needsAuthentication }) {
                Text("更新失敗 ·")
            }
            if let oldest = services.filter({ $0.fetchedAt != nil }).min(by: { $0.fetchedAt! < $1.fetchedAt! }) {
                Text(oldest.ageText(at: entry.date))
            } else { Text(entry.snapshot.loadError == nil ? "アプリで接続設定" : "共有データ読込失敗") }
        }.font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.8)
    }
}
