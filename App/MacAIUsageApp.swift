import SwiftUI
import AppKit

@main
struct MacAIUsageApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = UsageModel.shared
    var body: some Scene {
        Window("AI Usage", id: "main") {
            ContentView(model: model)
                .onOpenURL { url in
                    model.selectedService = Service(rawValue: url.lastPathComponent)
                    model.showSettings = url.host == "settings"
                    NSApp.activate(ignoringOtherApps: true)
                }
        }
        .defaultSize(width: 650, height: 650)
        .windowResizability(.contentMinSize)

        MenuBarExtra("AI Usage", systemImage: "chart.bar.xaxis") {
            MenuContent(model: model)
        }
        .menuBarExtraStyle(.window)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        #if DEBUG
        if CommandLine.arguments.contains("--inspect-grok-auth") {
            do {
                let credential = try Credentials.grokCredential()
                print("Grok access token expires at: \(credential.expiresAt?.description ?? "unknown")")
                print("Expired: \(credential.expiresAt.map { $0 <= Date() } ?? false)")
            } catch { print(error.localizedDescription) }
            NSApp.terminate(nil)
            return
        }
        if CommandLine.arguments.contains("--diagnose-grok-shape") {
            Task {
                do {
                    let client = ProviderClient()
                    print(try await client.diagnoseGrokShape())
                    let usage = await client.fetch(.grok, previous: ServiceUsage(service: .grok), interactive: false)
                    print("Grok: \(usage.state.label), \(usage.message ?? "")")
                    for window in usage.windows { print("\(window.title): 残り\(window.remainingText), \(window.resetText())") }
                }
                catch { print("Grok diagnostic failed: \(error.localizedDescription)") }
                NSApp.terminate(nil)
            }
            return
        }
        if CommandLine.arguments.contains("--verify-widget-refresh") {
            // Run beside the installed app: this process only sends the same request as the widget.
            Task {
                do {
                    _ = try await RefreshUsageIntent().perform()
                    print("Widget refresh request acknowledged by the installed app.")
                    for usage in SharedStore.load().services {
                        print("\(usage.service.name): \(usage.state.label), \(usage.windows.count) windows")
                    }
                } catch { print("Widget refresh verification failed: \(error.localizedDescription)") }
                NSApp.terminate(nil)
            }
            return
        }
        if let index = CommandLine.arguments.firstIndex(of: "--render-previews"),
           CommandLine.arguments.count > index + 1 {
            do { try PreviewRenderer.render(to: URL(fileURLWithPath: CommandLine.arguments[index + 1])) }
            catch { print("Preview rendering failed: \(error)") }
            NSApp.terminate(nil)
            return
        }
        #endif
        UsageModel.shared.start()
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

private struct MenuContent: View {
    @ObservedObject var model: UsageModel
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("残り").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                if model.refreshing { ProgressView().controlSize(.small) }
                Button { Task { await model.refresh(interactive: true) } } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(model.refreshing)
                .accessibilityLabel("使用状況を更新")
            }
            TimelineView(.periodic(from: .now, by: 60)) { context in
                VStack(alignment: .leading, spacing: 10) {
                    if let error = model.errorMessage ?? model.snapshot.loadError {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .font(.caption).foregroundStyle(.orange)
                    }
                    if model.snapshot.configuredServices.isEmpty {
                        Button("接続設定を開く") { show(settings: true) }
                    }
                    ForEach(model.snapshot.configuredServices) { usage in
                        Button { show(settings: false, service: usage.service) } label: {
                            CompactUsageRow(usage: usage, now: context.date)
                                .contentShape(Rectangle())
                        }.buttonStyle(.plain)
                    }
                    if let oldest = model.snapshot.configuredServices.filter({ $0.fetchedAt != nil })
                        .min(by: { $0.fetchedAt! < $1.fetchedAt! }) {
                        Text(oldest.ageText(at: context.date))
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
            Divider()
            HStack {
                Button("詳細") { show(settings: false) }
                Button("接続設定…") { show(settings: true) }
                Spacer()
                Button("終了") { NSApp.terminate(nil) }
                    .keyboardShortcut("q")
            }
        }
        .padding(14)
        .frame(width: 280)
    }
    private func show(settings: Bool, service: Service? = nil) {
        model.showSettings = settings
        model.selectedService = service
        openWindow(id: "main")
        NSApp.activate(ignoringOtherApps: true)
    }
}
