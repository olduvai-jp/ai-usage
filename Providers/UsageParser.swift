import Foundation

enum UsageError: LocalizedError {
    case missing(String), authentication(String), refreshFailed(String), invalidResponse, network(Int), timeout, keychain(OSStatus)
    var errorDescription: String? {
        switch self {
        case .missing(let message), .authentication(let message), .refreshFailed(let message): return message
        case .invalidResponse: return "使用状況の形式が未対応、または利用枠が返されませんでした。"
        case .network(let code): return code == 429 ? "取得回数の制限中です。しばらく待って更新してください。" : "サービスの取得エラー（HTTP \(code)）"
        case .timeout: return "取得がタイムアウトしました。"
        case .keychain: return "Keychainにアクセスできません。アプリから接続確認を実行してください。"
        }
    }
}

enum UsageParser {
    static func object(_ data: Data) throws -> [String: Any] {
        guard let result = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw UsageError.invalidResponse }
        return result
    }
    static func number(_ value: Any?) -> Double? {
        guard let value = value as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(), value.doubleValue.isFinite else { return nil }
        return value.doubleValue
    }
    static func date(_ value: Any?) -> Date? {
        if let seconds = number(value), seconds > 0 { return Date(timeIntervalSince1970: seconds) }
        guard let text = value as? String else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }
    static func window(id: String, kind: WindowKind, title: String, used: Any?, reset: Any?) -> QuotaWindow? {
        guard let used = number(used), used >= 0 else { return nil }
        return QuotaWindow(id: id, kind: kind, title: title, usedPercent: used, resetsAt: date(reset))
    }
    static func validated(_ windows: [QuotaWindow]) throws -> [QuotaWindow] {
        guard !windows.isEmpty else { throw UsageError.invalidResponse }
        return windows
    }
    static func periodLabel(_ minutes: Double?) -> String {
        if minutes == 10080 { return WindowKind.weekly.label }
        if let minutes, minutes >= 40320 && minutes <= 44640 { return WindowKind.monthly.label }
        if let minutes, minutes <= 1440 { return WindowKind.short.label }
        return "\(Int(minutes ?? 0))分枠"
    }
    static func codex(_ data: Data) throws -> [QuotaWindow] {
        let root = try object(data)
        let buckets = root["rateLimitsByLimitId"] as? [String: [String: Any]] ?? [:]
        let main = buckets["codex"] ?? root["rateLimits"] as? [String: Any] ?? [:]
        func parse(_ bucket: [String: Any], prefix: String, extra: Bool) -> [QuotaWindow] {
            // Codex exposes an internal limitId (e.g. base_model_inference) plus the display
            // name it uses in its own UI (limitName) and the model the bucket applies to.
            let name = ["limitName", "normalModelSlug"]
                .compactMap { bucket[$0] as? String }
                .first { !$0.isEmpty } ?? prefix
            return ["primary", "secondary"].compactMap { key in
                guard let value = bucket[key] as? [String: Any] else { return nil }
                let minutes = number(value["windowDurationMins"])
                let kind: WindowKind = extra ? .extra : minutes == 10080 ? .weekly :
                    (minutes.map { $0 >= 40320 && $0 <= 44640 } ?? false) ? .monthly :
                    (minutes.map { $0 <= 1440 } ?? false) ? .short : .extra
                let period = extra ? periodLabel(minutes) : kind == .extra ? "\(Int(minutes ?? 0))分枠" : kind.label
                let title = extra ? "\(name) \(period)" : period
                return window(id: "\(prefix)-\(key)", kind: kind, title: title,
                              used: value["usedPercent"], reset: value["resetsAt"])
            }
        }
        var windows = parse(main, prefix: "codex", extra: false)
        for key in buckets.keys.sorted() where key != "codex" {
            windows += parse(buckets[key]!, prefix: key, extra: true)
        }
        return try validated(windows)
    }
    static func claude(_ data: Data) throws -> [QuotaWindow] {
        let root = try object(data)
        var windows: [QuotaWindow] = []
        for key in root.keys.sorted() where key == "five_hour" || key.hasPrefix("seven_day") {
            guard let value = root[key] as? [String: Any] else { continue }
            let kind: WindowKind = key == "five_hour" ? .short : key == "seven_day" ? .weekly : .extra
            if let parsed = window(id: key, kind: kind, title: kind == .extra ? key.replacingOccurrences(of: "seven_day_", with: "") + " 週間" : kind.label,
                                   used: value["utilization"], reset: value["resets_at"]) { windows.append(parsed) }
        }
        for (index, value) in (root["limits"] as? [[String: Any]] ?? []).enumerated() {
            guard value["is_active"] as? Bool != false,
                  value["kind"] as? String == "weekly_scoped" else { continue }
            let scope = value["scope"] as? [String: Any]
            let model = scope?["model"] as? [String: Any]
            let name = model?["display_name"] as? String ?? "モデル別"
            let isCommon = name.lowercased() == "all models"
            if isCommon && windows.contains(where: { $0.kind == .weekly }) { continue }
            if let parsed = window(id: "scoped-\(index)", kind: isCommon ? .weekly : .extra,
                                   title: isCommon ? "週間" : "\(name) 週間", used: value["percent"], reset: value["resets_at"]) { windows.append(parsed) }
        }
        let order: [WindowKind] = [.short, .weekly, .monthly, .extra]
        return try validated(windows.sorted { order.firstIndex(of: $0.kind)! < order.firstIndex(of: $1.kind)! })
    }
    static func opencode(_ data: Data) throws -> [QuotaWindow] {
        let root = try object(data)
        guard let usage = root["usage"] as? [String: Any] else { throw UsageError.invalidResponse }
        let mapping: [(String, WindowKind)] = [("rolling", .short), ("weekly", .weekly), ("monthly", .monthly)]
        return try validated(mapping.compactMap { key, kind in
            guard let value = usage[key] as? [String: Any] else { return nil }
            return window(id: key, kind: kind, title: kind.label, used: value["percent"], reset: value["resetsAt"])
        })
    }
}
