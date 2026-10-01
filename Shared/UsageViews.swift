import SwiftUI

func quotaColor(_ remaining: Double) -> Color {
    remaining <= 5 ? .red : remaining <= 20 ? .orange : .primary
}

struct ServiceIcon: View {
    let service: Service
    var size: CGFloat = 22
    var body: some View {
        Image(service.rawValue)
            .resizable().scaledToFit().frame(width: size, height: size)
            .accessibilityLabel(service.name)
    }
}

struct RemainingValue: View {
    let window: QuotaWindow
    var compact = false
    var body: some View {
        HStack(spacing: 2) {
            Text(compact ? window.kind.abbreviation : window.title)
                .foregroundStyle(.secondary)
            Text(window.remainingText).foregroundStyle(quotaColor(window.remaining))
                .monospacedDigit().fontWeight(.semibold)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(window.title)、残り\(window.remainingText)")
    }
}

/// Pure SwiftUI geometry also renders in WidgetKit snapshots and ImageRenderer.
struct QuotaBar: View {
    let remaining: Double
    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(.primary.opacity(0.1))
                Capsule().fill(quotaColor(remaining))
                    .frame(width: geometry.size.width * max(0, min(100, remaining)) / 100)
            }
        }.frame(height: 5)
        .accessibilityHidden(true)
    }
}

struct UsageWarning: View {
    let usage: ServiceUsage
    let now: Date
    var body: some View {
        if usage.needsWarning(at: now) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.caption2).foregroundStyle(.orange)
                .accessibilityLabel("\(usage.state.label)。\(usage.ageText(at: now))")
        }
    }
}
