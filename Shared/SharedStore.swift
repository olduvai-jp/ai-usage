import Foundation

enum SharedStore {
    static let group = "TUYKQ3PV6F.jp.olduvai.MacAIUsage"
    static let refreshNotification = "jp.olduvai.MacAIUsage.refresh"
    static let widgetKind = "AIUsageWidget"

    static func directory() throws -> URL {
        guard let url = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) else {
            throw StoreError.unavailable
        }
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    static func load() -> UsageSnapshot {
        do {
            let url = try directory().appendingPathComponent("usage.json")
            let data: Data
            do { data = try Data(contentsOf: url) }
            catch let error as CocoaError where error.code == .fileReadNoSuchFile { return UsageSnapshot() }
            return try JSONDecoder().decode(UsageSnapshot.self, from: data)
        } catch {
            return UsageSnapshot(loadError: "共有データを読めません。アプリを開いて更新してください。")
        }
    }
    static func save(_ snapshot: UsageSnapshot) throws {
        let data = try JSONEncoder().encode(snapshot)
        try data.write(to: directory().appendingPathComponent("usage.json"), options: .atomic)
    }
    static func requestRefresh() throws -> String {
        let id = UUID().uuidString
        try Data(id.utf8).write(to: directory().appendingPathComponent("refresh-request"), options: .atomic)
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(refreshNotification as CFString), nil, nil, true)
        return id
    }
    static func pendingRequest() -> String? {
        guard let url = try? directory().appendingPathComponent("refresh-request") else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }
    enum StoreError: LocalizedError {
        case unavailable
        var errorDescription: String? { "共有領域を開けません。アプリの署名とApp Groupを確認してください。" }
    }
}
