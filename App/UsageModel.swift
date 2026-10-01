import AppKit
import SwiftUI
import WidgetKit
import ServiceManagement

@MainActor
final class UsageModel: ObservableObject {
    static let shared = UsageModel()
    @Published var snapshot = SharedStore.load()
    @Published var refreshing = false
    @Published var errorMessage: String?
    @Published var selectedService: Service?
    @Published var showSettings = false
    @Published var loginEnabled = SMAppService.mainApp.status == .enabled
    private let client = ProviderClient()
    private var scheduler: NSBackgroundActivityScheduler?
    private var requestTimer: Timer?
    private var started = false

    func start() {
        guard !started else { return }
        started = true
        let scheduler = NSBackgroundActivityScheduler(identifier: "jp.daiki.MacAIUsage.poll")
        scheduler.interval = 20 * 60
        scheduler.tolerance = 5 * 60
        scheduler.repeats = true
        scheduler.schedule { [weak self] completion in
            Task { @MainActor in
                await self?.refresh()
                completion(.finished)
            }
        }
        self.scheduler = scheduler
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), nil,
            { _, _, _, _, _ in
                Task { @MainActor in await UsageModel.shared.handlePendingRequest() }
            }, SharedStore.refreshNotification as CFString, nil, .deliverImmediately)
        // Slow fallback for coalesced/lost notifications, without frequent idle wake-ups.
        requestTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in
                await self?.handlePendingRequest()
            }
        }
        requestTimer?.tolerance = 15
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification,
                                                         object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }
        if !UserDefaults.standard.bool(forKey: "configuredLoginItem") {
            setLoginEnabled(true)
            UserDefaults.standard.set(true, forKey: "configuredLoginItem")
        }
        Task { await refresh() }
    }

    func refresh(interactive: Bool = false) async {
        guard !refreshing else { return }
        refreshing = true
        defer {
            refreshing = false
            Task { await handlePendingRequest() }
        }
        let request = SharedStore.pendingRequest()
        let previous = snapshot
        await withTaskGroup(of: ServiceUsage.self) { group in
            for service in Service.allCases {
                group.addTask { [client] in
                    await client.fetch(service, previous: previous[service], interactive: interactive)
                }
            }
            for await result in group { snapshot[result.service] = result }
        }
        snapshot.refreshedAt = Date()
        snapshot.loadError = nil
        snapshot.completedRequest = request
        do {
            try SharedStore.save(snapshot)
            errorMessage = nil
            WidgetCenter.shared.reloadTimelines(ofKind: SharedStore.widgetKind)
        } catch { errorMessage = error.localizedDescription }
    }

    private func handlePendingRequest() async {
        guard !refreshing, let request = SharedStore.pendingRequest(), request != snapshot.completedRequest else { return }
        await refresh()
    }

    func saveGoKey(_ key: String) {
        do {
            let clean = key.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !clean.isEmpty, !clean.contains(where: \.isWhitespace) else {
                errorMessage = "空白を含まないAPIキーを入力してください。"; return
            }
            try Credentials.saveGoKey(clean)
            snapshot[.opencode] = ServiceUsage(service: .opencode)
            try SharedStore.save(snapshot)
            Task { await refresh(interactive: true) }
        } catch { errorMessage = error.localizedDescription }
    }

    func setLoginEnabled(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
            loginEnabled = SMAppService.mainApp.status == .enabled
            if enabled && !loginEnabled { errorMessage = "システム設定 → 一般 → ログイン項目でAI Usageを許可してください。" }
        } catch { errorMessage = "自動起動を設定できませんでした：\(error.localizedDescription)" }
    }
}
