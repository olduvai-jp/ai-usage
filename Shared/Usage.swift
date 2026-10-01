import Foundation

enum Service: String, Codable, CaseIterable, Identifiable, Sendable {
    case codex, claude, opencode, grok
    var id: String { rawValue }
    var name: String {
        switch self {
        case .codex: return "Codex"
        case .claude: return "Claude Code"
        case .opencode: return "OpenCode Go"
        case .grok: return "Grok"
        }
    }
    var detailURL: URL { URL(string: "macaiusage://service/\(rawValue)")! }
}

enum WindowKind: String, Codable, Sendable {
    case short, weekly, monthly, current, extra
    var label: String {
        switch self {
        case .short: return "短時間"
        case .weekly: return "週間"
        case .monthly: return "月間"
        case .current: return "契約枠"
        case .extra: return "追加枠"
        }
    }
    var abbreviation: String {
        switch self {
        case .short: return "短"
        case .weekly: return "週"
        case .monthly: return "月"
        case .current: return "枠"
        case .extra: return "他"
        }
    }
}

struct QuotaWindow: Codable, Identifiable, Equatable, Sendable {
    let id: String
    let kind: WindowKind
    let title: String
    let usedPercent: Double
    let resetsAt: Date?
    var remaining: Double { max(0, min(100, 100 - usedPercent)) }
    // Round down: never claim more quota remains than the service reported.
    var remainingText: String { "\(Int(remaining.rounded(.down)))%" }
    func resetText(at now: Date = Date()) -> String {
        guard let resetsAt else { return "リセット時刻不明" }
        guard resetsAt > now else { return "リセット確認待ち" }
        let minutes = max(1, Int(ceil(resetsAt.timeIntervalSince(now) / 60)))
        if minutes >= 1440 { return "あと\(minutes / 1440)日\((minutes % 1440) / 60)時間" }
        if minutes >= 60 { return "あと\(minutes / 60)時間\(minutes % 60)分" }
        return "あと\(minutes)分"
    }
}

enum ConnectionState: String, Codable, Sendable {
    case unconnected, ready, failed, needsAuthentication
    var label: String {
        switch self {
        case .unconnected: return "未接続"
        case .ready: return "接続済み"
        case .failed: return "更新失敗"
        case .needsAuthentication: return "再接続が必要"
        }
    }
}

struct ServiceUsage: Codable, Identifiable, Sendable {
    let service: Service
    var windows: [QuotaWindow] = []
    var fetchedAt: Date?
    var attemptedAt: Date?
    var state: ConnectionState = .unconnected
    var message: String?
    var source: String?
    // A one-way fingerprint prevents carrying quota across credential/account changes.
    var ownerFingerprint: String?
    var id: Service { service }
    var isConfigured: Bool { state != .unconnected }
    mutating func markCredentialsMissing() {
        // A lost established connection remains visible, including its last known quota.
        state = ownerFingerprint != nil || fetchedAt != nil ? .needsAuthentication : .unconnected
    }
    var commonWindows: [QuotaWindow] { windows.filter { $0.kind != .extra } }
    func window(_ kind: WindowKind) -> QuotaWindow? { windows.first { $0.kind == kind } }
    func needsWarning(at now: Date = Date()) -> Bool {
        guard isConfigured else { return false }
        return state == .failed || state == .needsAuthentication
            || (fetchedAt.map { now.timeIntervalSince($0) > 3600 } ?? false)
            || windows.contains { $0.remaining == 0 || ($0.resetsAt.map { $0 <= now } ?? false) }
    }
    func ageText(at now: Date = Date()) -> String {
        guard let fetchedAt else { return "未取得" }
        let minutes = max(0, Int(now.timeIntervalSince(fetchedAt) / 60))
        if minutes < 1 { return "取得したばかり" }
        if minutes < 60 { return "最終取得\(minutes)分前" }
        if minutes < 1440 { return "最終取得\(minutes / 60)時間前" }
        return "最終取得\(minutes / 1440)日前"
    }
}

struct UsageSnapshot: Codable, Sendable {
    var services: [ServiceUsage] = Service.allCases.map { ServiceUsage(service: $0) }
    var refreshedAt: Date?
    var completedRequest: String?
    // Local read status only; never written into the shared cache.
    var loadError: String? = nil
    subscript(_ service: Service) -> ServiceUsage {
        get { services.first { $0.service == service } ?? ServiceUsage(service: service) }
        set {
            if let index = services.firstIndex(where: { $0.service == service }) { services[index] = newValue }
            else { services.append(newValue) }
        }
    }
    var configuredServices: [ServiceUsage] { Service.allCases.map { self[$0] }.filter(\.isConfigured) }
    var oldestFetch: Date? { configuredServices.compactMap(\.fetchedAt).min() }
}

extension UsageSnapshot {
    private enum CodingKeys: String, CodingKey { case services, refreshedAt, completedRequest }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        services = try container.decode([KnownService].self, forKey: .services).compactMap(\.usage)
        refreshedAt = try container.decodeIfPresent(Date.self, forKey: .refreshedAt)
        completedRequest = try container.decodeIfPresent(String.self, forKey: .completedRequest)
    }

    /// A newer app may add providers before the system restarts the older widget.
    /// Skip unknown providers, but do not conceal corrupt data for known providers.
    private struct KnownService: Decodable {
        var usage: ServiceUsage?
        private enum CodingKeys: String, CodingKey { case service }
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let name = try container.decode(String.self, forKey: .service)
            if Service(rawValue: name) != nil { usage = try ServiceUsage(from: decoder) }
        }
    }
}
