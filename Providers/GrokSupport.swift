import Foundation

/// SuperGrok's CLI billing response; on-demand spending is deliberately not a quota fallback.
enum GrokSupport {
    struct Credential: Sendable {
        let token: String
        let expiresAt: Date?
        var accountIdentity: String? = nil
    }

    static func refreshIfNeeded(_ credential: Credential, now: Date = Date(),
                                runCLI: () async throws -> Void,
                                reload: () throws -> Credential) async throws -> Credential {
        guard let expiry = credential.expiresAt, expiry <= now.addingTimeInterval(60) else { return credential }
        let started = Date()
        try await runCLI()
        let refreshed = try reload()
        guard let newExpiry = refreshed.expiresAt,
              newExpiry > now.addingTimeInterval(Date().timeIntervalSince(started)) else {
            throw UsageError.refreshFailed("Grokの自動認証更新が完了しませんでした。通信状態とGrok CLIを確認してください。CLIでもログインを求められる場合は grok login を実行してください。")
        }
        return refreshed
    }

    static func credential(_ data: Data) throws -> Credential {
        let root = try UsageParser.object(data)
        let scopes = root.keys.filter {
            $0.hasPrefix("https://auth.x.ai::") || $0 == "https://accounts.x.ai/sign-in"
        }.sorted()
        let entries = scopes.compactMap { scope -> (String, [String: Any])? in
            guard let entry = root[scope] as? [String: Any],
                  let key = entry["key"] as? String, !key.isEmpty else { return nil }
            return (scope, entry)
        }
        // Prefer SuperGrok OIDC credentials; within that scope prefer the latest expiry.
        let ordered = entries.sorted { lhs, rhs in
            let leftOIDC = lhs.0.hasPrefix("https://auth.x.ai::")
            let rightOIDC = rhs.0.hasPrefix("https://auth.x.ai::")
            if leftOIDC != rightOIDC { return leftOIDC }
            return (UsageParser.date(lhs.1["expires_at"]) ?? .distantPast)
                > (UsageParser.date(rhs.1["expires_at"]) ?? .distantPast)
        }
        guard let entry = ordered.first?.1, let token = entry["key"] as? String else {
            throw UsageError.missing("grok login でSuperGrokにログイン後、接続確認してください。")
        }
        guard !token.contains(where: \.isWhitespace) else { throw UsageError.invalidResponse }
        if (entry["principal_type"] as? String)?.lowercased() == "team" {
            throw UsageError.authentication("個人のSuperGrokアカウントで grok login を実行してください。")
        }
        let expiry = UsageParser.date(entry["expires_at"])
        if let raw = entry["expires_at"] as? String, !raw.isEmpty, expiry == nil {
            throw UsageError.invalidResponse
        }
        let userID = entry["user_id"] as? String
        let identity = userID.flatMap { $0.isEmpty ? nil : "grok-personal:\($0)" }
        return Credential(token: token, expiresAt: expiry, accountIdentity: identity)
    }

    static func windows(_ data: Data) throws -> [QuotaWindow] {
        let root = try UsageParser.object(data)
        guard let config = root["config"] as? [String: Any],
              let used = UsageParser.number(config["creditUsagePercent"]), used >= 0 else {
            throw UsageError.invalidResponse
        }
        let period = config["currentPeriod"] as? [String: Any]
        let currentEnd = UsageParser.date(period?["end"])
        let end = currentEnd ?? UsageParser.date(config["billingPeriodEnd"])
        let start = UsageParser.date(currentEnd == nil ? config["billingPeriodStart"] : period?["start"])
        var kind: WindowKind = .current
        if let start, let end, end > start {
            let minutes = end.timeIntervalSince(start) / 60
            if abs(minutes - 10080) < 1 { kind = .weekly }
            else if (40320...44640).contains(minutes) { kind = .monthly }
            else if minutes <= 1440 { kind = .short }
        }
        return [QuotaWindow(id: "grok-subscription", kind: kind, title: "SuperGrok \(kind.label)",
                            usedPercent: used, resetsAt: end)]
    }
}
