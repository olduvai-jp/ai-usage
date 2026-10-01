#if DEBUG
import SwiftUI
import WidgetKit
import AppKit

/// Development-only layout proofs using explicit synthetic data; never saves to the live cache.
@MainActor
enum PreviewRenderer {
    static func render(to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let now = Date()
        var snapshot = UsageSnapshot()
        for (index, service) in Service.allCases.enumerated() {
            snapshot[service].state = .ready
            snapshot[service].fetchedAt = now.addingTimeInterval(-300)
            snapshot[service].windows = [
                QuotaWindow(id: "short", kind: .short, title: "短時間", usedPercent: Double(index * 15 + 20), resetsAt: now.addingTimeInterval(8100)),
                QuotaWindow(id: "weekly", kind: .weekly, title: "週間", usedPercent: [28, 95, 20, 42][index], resetsAt: now.addingTimeInterval(172800))
            ]
            if service == .opencode {
                snapshot[service].windows.append(QuotaWindow(id: "monthly", kind: .monthly, title: "月間", usedPercent: 37, resetsAt: now.addingTimeInterval(864000)))
            }
        }
        let sizes: [(String, WidgetFamily, CGFloat, CGFloat)] = [
            ("small", .systemSmall, 170, 170), ("medium", .systemMedium, 364, 170), ("large", .systemLarge, 364, 382)
        ]
        for (name, family, width, height) in sizes {
            for scheme in [ColorScheme.light, .dark] {
                let content = UsageWidgetView(entry: UsageEntry(date: now, snapshot: snapshot), previewFamily: family)
                    .environment(\.colorScheme, scheme)
                    .environment(\.locale, Locale(identifier: "ja_JP"))
                    .padding(16).frame(width: width, height: height)
                    .background(scheme == .dark ? Color(white: 0.12) : .white)
                let renderer = ImageRenderer(content: content)
                renderer.scale = 2
                guard let image = renderer.cgImage else { continue }
                let bitmap = NSBitmapImageRep(cgImage: image)
                if let png = bitmap.representation(using: .png, properties: [:]) {
                    try png.write(to: directory.appendingPathComponent("\(name)-\(scheme == .dark ? "dark" : "light").png"))
                }
            }
        }
    }
}
#endif
