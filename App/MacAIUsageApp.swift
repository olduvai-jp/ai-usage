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
        Button("使用状況を表示") { show(settings: false) }
        Button(model.refreshing ? "更新中…" : "今すぐ更新") { Task { await model.refresh(interactive: true) } }
            .disabled(model.refreshing)
        Divider()
        Button("接続設定…") { show(settings: true) }
        Button("AI Usageを終了") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
    private func show(settings: Bool) {
        model.showSettings = settings
        model.selectedService = nil
        openWindow(id: "main")
        NSApp.activate(ignoringOtherApps: true)
    }
}
