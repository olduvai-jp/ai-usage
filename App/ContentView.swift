import SwiftUI
import AppKit

struct ContentView: View {
    @ObservedObject var model: UsageModel
    @State private var goKey = ""
    @AppStorage("codexPath") private var codexPath = "/opt/homebrew/bin/codex"

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("AI Usage").font(.largeTitle.bold())
                    Text("定額プランの残り枠").foregroundStyle(.secondary)
                }
                Spacer()
                if model.refreshing { ProgressView().controlSize(.small) }
                Button { Task { await model.refresh(interactive: true) } } label: {
                    Label("更新", systemImage: "arrow.clockwise")
                }.disabled(model.refreshing)
            }.padding(24)
            Picker("画面", selection: $model.showSettings) {
                Text("使用状況").tag(false)
                Text("接続設定").tag(true)
            }.pickerStyle(.segmented).labelsHidden().padding(.horizontal, 24).padding(.bottom, 16)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let error = model.errorMessage {
                        Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                    }
                    if model.showSettings { settings }
                    else {
                        if model.selectedService != nil {
                            Button("すべてのサービスを表示") { model.selectedService = nil }
                        }
                        ForEach(model.snapshot.configuredServices.filter { model.selectedService == nil || $0.service == model.selectedService }) { usage in
                            detail(usage)
                        }
                        if model.snapshot.configuredServices.isEmpty {
                            Button("接続設定を開く") { model.showSettings = true }
                        }
                        Text("自動取得は約20分ごと。ウィジェットへの反映はmacOSの判断で遅れる場合があります。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }.padding(24)
            }
        }.frame(minWidth: 580, minHeight: 500)
    }

    private func detail(_ usage: ServiceUsage) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    ServiceIcon(service: usage.service)
                    Text(usage.service.name).font(.headline)
                    UsageWarning(usage: usage, now: Date())
                    Spacer()
                    Text(usage.state.label).font(.caption).foregroundStyle(.secondary)
                }
                if let message = usage.message {
                    Text(message).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                    Button("接続設定を開く") { model.showSettings = true }
                }
                if usage.windows.isEmpty { Text("利用枠は未取得です").foregroundStyle(.secondary) }
                ForEach(usage.windows) { window in
                    VStack(alignment: .leading, spacing: 5) {
                        HStack {
                            Text(window.title)
                            Spacer()
                            Text("残り \(window.remainingText)").monospacedDigit().foregroundStyle(quotaColor(window.remaining))
                        }
                        QuotaBar(remaining: window.remaining)
                        HStack {
                            Text(window.resetText())
                            Spacer()
                            if let date = window.resetsAt {
                                Text(date.formatted(.dateTime.locale(Locale(identifier: "ja_JP")).month().day().hour().minute()))
                            }
                        }.font(.caption).foregroundStyle(.secondary)
                    }
                }
                HStack {
                    Text(usage.ageText())
                    Spacer()
                    Text(usage.source ?? "")
                }.font(.caption2).foregroundStyle(.secondary)
            }.padding(8)
        }
    }

    private var settings: some View {
        VStack(alignment: .leading, spacing: 20) {
            connectionSection(.codex) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("インストール済みCodex CLIのChatGPTログインを利用します。")
                    HStack {
                        TextField("Codex実行ファイル", text: $codexPath)
                        Button("選択…") {
                            let panel = NSOpenPanel()
                            panel.canChooseDirectories = false
                            if panel.runModal() == .OK, let url = panel.url { codexPath = url.path }
                        }
                    }
                    command("codex login", explanation: "接続先を変える場合はターミナルでログイン後、接続確認してください。")
                }.padding(8)
            }
            connectionSection(.claude) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Claude Codeの既存ログイン情報を読み取ります。接続確認時にKeychainの許可を求める場合があります。")
                    command("claude auth login", explanation: "認証切れの場合はClaude Codeを起動するか、再ログインしてください。")
                    Text("非公開仕様の使用状況APIを利用します。認証情報はClaude Code側で管理し、このアプリから書き換えません。")
                        .font(.caption).foregroundStyle(.secondary)
                }.padding(8)
            }
            connectionSection(.opencode) {
                VStack(alignment: .leading, spacing: 8) {
                    Link("OpenCode Consoleを開く", destination: URL(string: "https://opencode.ai/auth")!)
                    HStack {
                        SecureField("GoのAPIキー（保存済みの値は表示しません）", text: $goKey)
                        Button("保存して接続") { model.saveGoKey(goKey); goKey = "" }
                            .disabled(goKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.refreshing)
                    }
                    Text("キーはこのMacのKeychainに保存します。Zenの残高ではなくGoの定額枠を取得します。")
                        .font(.caption).foregroundStyle(.secondary)
                }.padding(8)
            }
            connectionSection(.grok) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Grok CLIのSuperGrokログインを利用します。")
                    command("grok login", explanation: "SuperGrokのアカウントでログイン後、接続確認してください。")
                    Link("Grok Buildを開く", destination: URL(string: "https://grok.com/build")!)
                    Text("~/.grok/auth.jsonから契約枠を取得します。認証期限が近づくと grok models でCLIの自動更新を利用します。会話の生成やAPI残高の表示は行いません。")
                        .font(.caption).foregroundStyle(.secondary)
                }.padding(8)
            }
            HStack {
                Button("接続確認") { Task { await model.refresh(interactive: true) } }
                    .disabled(model.refreshing)
                Spacer()
                Toggle("ログイン時に起動", isOn: Binding(get: { model.loginEnabled }, set: { model.setLoginEnabled($0) }))
            }
            Text("ウィジェットを追加：デスクトップを右クリック →「ウィジェットを編集」→「AI Usage」。小・中・大から選べます。")
                .font(.callout).foregroundStyle(.secondary)
        }
    }
    @ViewBuilder
    private func connectionSection<Content: View>(_ service: Service, @ViewBuilder content: @escaping () -> Content) -> some View {
        if model.snapshot[service].isConfigured {
            GroupBox(service.name, content: content)
        } else {
            DisclosureGroup {
                content()
            } label: {
                HStack {
                    Text(service.name)
                    Text("未設定").font(.caption).foregroundStyle(.secondary)
                }
            }
            .disclosureGroupStyle(ClickableDisclosureGroupStyle())
        }
    }

    private func command(_ text: String, explanation: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(explanation).font(.caption).foregroundStyle(.secondary)
            HStack {
                Text(text).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                Button("コピー") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string) }
            }
        }
    }
}

private struct ClickableDisclosureGroupStyle: DisclosureGroupStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation { configuration.isExpanded.toggle() }
            } label: {
                HStack {
                    Image(systemName: configuration.isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption.weight(.semibold))
                        .frame(width: 12)
                    configuration.label
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(configuration.isExpanded ? "展開中" : "折りたたみ")
            if configuration.isExpanded {
                configuration.content
            }
        }
    }
}
