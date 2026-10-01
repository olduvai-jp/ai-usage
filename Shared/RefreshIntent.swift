import AppIntents
import Foundation
import WidgetKit

struct RefreshUsageIntent: AppIntent {
    static var title: LocalizedStringResource = "使用状況を更新"
    static var description = IntentDescription("バックグラウンドのAI Usageに最新情報の取得を依頼します。")
    static var openAppWhenRun: Bool = false

    func perform() async throws -> some IntentResult {
        let request = try SharedStore.requestRefresh()
        for _ in 0..<55 {
            try await Task.sleep(for: .seconds(1))
            if SharedStore.load().completedRequest == request {
                WidgetCenter.shared.reloadTimelines(ofKind: SharedStore.widgetKind)
                return .result()
            }
        }
        throw RefreshError.appUnavailable
    }

    enum RefreshError: LocalizedError {
        case appUnavailable
        var errorDescription: String? { "更新を確認できませんでした。AI Usageを開いて接続状態を確認してください。" }
    }
}
