import XCTest
@testable import UsageCore

final class UsageCoreTests: XCTestCase {
    private func data(_ text: String) -> Data { Data(text.utf8) }

    func testFutureProviderDoesNotInvalidateKnownProviderCache() throws {
        var snapshot = UsageSnapshot()
        snapshot[.codex].state = .ready
        snapshot[.codex].windows = [QuotaWindow(id: "week", kind: .weekly, title: "週間", usedPercent: 25, resetsAt: nil)]
        var root = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(snapshot)) as? [String: Any])
        var services = try XCTUnwrap(root["services"] as? [[String: Any]])
        services.append(["service": "future-provider", "state": "new-state", "windows": []])
        root["services"] = services
        let decoded = try JSONDecoder().decode(UsageSnapshot.self, from: JSONSerialization.data(withJSONObject: root))
        XCTAssertEqual(decoded[.codex].windows.first?.remaining, 75)
        XCTAssertEqual(decoded.configuredServices.map(\.service), [.codex])
        services[0]["windows"] = "invalid-known-provider-data"
        root["services"] = services
        XCTAssertThrowsError(try JSONDecoder().decode(UsageSnapshot.self, from: JSONSerialization.data(withJSONObject: root)))
    }

    func testLocalCacheReadErrorIsNotPersisted() throws {
        let snapshot = UsageSnapshot(loadError: "Local read failure")
        let restored = try JSONDecoder().decode(UsageSnapshot.self, from: JSONEncoder().encode(snapshot))
        XCTAssertNil(restored.loadError)
    }

    func testUnconfiguredServicesDoNotOccupyRowsOrWarn() {
        var snapshot = UsageSnapshot()
        // An old failed probe without subscription credentials becomes unconfigured.
        snapshot[.claude].state = .needsAuthentication
        snapshot[.claude].markCredentialsMissing()
        snapshot[.codex].state = .ready
        snapshot[.opencode].state = .failed
        snapshot[.opencode].ownerFingerprint = "configured-key"
        XCTAssertEqual(snapshot.configuredServices.map(\.service), [.codex, .opencode])
        XCTAssertFalse(snapshot[.claude].needsWarning())
        XCTAssertTrue(snapshot[.opencode].needsWarning())
        XCTAssertTrue(UsageSnapshot().configuredServices.isEmpty)
    }

    func testLostCredentialsKeepConfiguredServiceAndCachedQuotaVisible() throws {
        var usage = ServiceUsage(service: .opencode)
        usage.ownerFingerprint = "configured-key"
        // Even a key that has never successfully fetched quota must not silently disappear.
        usage.markCredentialsMissing()
        XCTAssertTrue(usage.isConfigured)
        XCTAssertTrue(usage.needsWarning())
        usage.windows = [QuotaWindow(id: "week", kind: .weekly, title: "週間", usedPercent: 25, resetsAt: nil)]
        usage.fetchedAt = Date(timeIntervalSince1970: 123)
        usage.markCredentialsMissing()
        let restored = try JSONDecoder().decode(ServiceUsage.self, from: JSONEncoder().encode(usage))
        XCTAssertTrue(restored.isConfigured)
        XCTAssertEqual(restored.windows.first?.remaining, 75)
        XCTAssertEqual(restored.fetchedAt, usage.fetchedAt)
    }

    func testCodexUsesDurationsRatherThanPrimaryPosition() throws {
        let windows = try UsageParser.codex(data("""
        {"rateLimits":{"primary":{"usedPercent":21,"windowDurationMins":10080,"resetsAt":2000000000},
        "secondary":{"usedPercent":2,"windowDurationMins":300,"resetsAt":1900000000}}}
        """))
        XCTAssertEqual(windows.first?.kind, .weekly)
        XCTAssertEqual(windows.first?.remaining, 79)
        XCTAssertEqual(windows.last?.kind, .short)
        XCTAssertEqual(windows.first?.resetsAt, Date(timeIntervalSince1970: 2000000000))
    }

    func testCodexBucketsDoNotDuplicateCommonQuota() throws {
        let windows = try UsageParser.codex(data("""
        {"rateLimits":{"primary":{"usedPercent":99,"windowDurationMins":300}},
        "rateLimitsByLimitId":{"codex":{"primary":{"usedPercent":20,"windowDurationMins":300}},
        "review":{"primary":{"usedPercent":100,"windowDurationMins":10080}}}}
        """))
        XCTAssertEqual(windows.count, 2)
        XCTAssertEqual(windows[0].remaining, 80)
        XCTAssertEqual(windows[1].kind, .extra)
        XCTAssertEqual(windows[1].remaining, 0)
        XCTAssertEqual(windows[1].title, "review 週間")
    }

    func testCodexAdditionalBucketUsesDisplayNameRatherThanInternalId() throws {
        let windows = try UsageParser.codex(data("""
        {"rateLimits":{"primary":{"usedPercent":99,"windowDurationMins":10080}},
        "rateLimitsByLimitId":{"codex":{"primary":{"usedPercent":99,"windowDurationMins":10080}},
        "base_model_inference":{"limitId":"base_model_inference","limitName":"gpt-reserve",
        "normalModelSlug":"gpt-5.6-luna","primary":{"usedPercent":0,"windowDurationMins":10080}}}}
        """))
        XCTAssertEqual(windows.count, 2)
        XCTAssertEqual(windows[0].title, "週間")
        XCTAssertEqual(windows[1].kind, .extra)
        XCTAssertEqual(windows[1].title, "gpt-reserve 週間")
        XCTAssertEqual(windows[1].remaining, 100)
    }

    func testCodexAdditionalBucketFallsBackToModelSlugOrKey() throws {
        let slug = try UsageParser.codex(data("""
        {"rateLimits":{"primary":{"usedPercent":50,"windowDurationMins":300}},
        "rateLimitsByLimitId":{"codex":{"primary":{"usedPercent":50,"windowDurationMins":300}},
        "base_model_inference":{"normalModelSlug":"gpt-5.6-luna","primary":{"usedPercent":0,"windowDurationMins":300}}}}
        """))
        XCTAssertEqual(slug[1].title, "gpt-5.6-luna 短時間")
        let key = try UsageParser.codex(data("""
        {"rateLimits":{"primary":{"usedPercent":50,"windowDurationMins":300}},
        "rateLimitsByLimitId":{"codex":{"primary":{"usedPercent":50,"windowDurationMins":300}},
        "feature_x":{"primary":{"usedPercent":0,"windowDurationMins":300}}}}
        """))
        XCTAssertEqual(key[1].title, "feature_x 短時間")
    }

    func testGoPercentIsNotFractionAndNullIsUnknown() throws {
        let windows = try UsageParser.opencode(data("""
        {"usage":{"rolling":{"percent":1,"resetsAt":"2026-10-01T03:00:00.123Z"},
        "weekly":{"percent":null},"monthly":{"percent":76.4,"resetsAt":"2026-10-30T03:00:00Z"}}}
        """))
        XCTAssertEqual(windows.count, 2)
        XCTAssertEqual(windows[0].remaining, 99)
        XCTAssertEqual(windows[1].remainingText, "23%")
        XCTAssertNotNil(windows[0].resetsAt)
        XCTAssertNotNil(windows[1].resetsAt)
        XCTAssertFalse(windows.contains { $0.kind == .weekly })
    }

    func testClaudeExcludesSpendingAndPreservesScopedLimits() throws {
        let windows = try UsageParser.claude(data("""
        {"five_hour":{"utilization":12,"resets_at":"2026-10-01T03:00:00Z"},
        "seven_day":{"utilization":85},"seven_day_sonnet":{"utilization":100},
        "extra_usage":{"utilization":50},
        "limits":[{"kind":"weekly_scoped","percent":36,"scope":{"model":{"display_name":"Fable"}}},
        {"kind":"weekly_scoped","percent":10,"is_active":false}]}
        """))
        XCTAssertEqual(windows.count, 4)
        XCTAssertEqual(windows[0].kind, .short)
        XCTAssertEqual(windows[1].kind, .weekly)
        XCTAssertEqual(windows.filter { $0.kind == .monthly }.count, 0)
        XCTAssertTrue(windows.contains { $0.title == "Fable 週間" })
    }

    func testMissingMalformedAndBooleanUsageNeverBecomeFullQuota() {
        for json in ["{}", "{\"usage\":{}}", "{\"usage\":{\"weekly\":{\"percent\":true}}}",
                     "{\"usage\":{\"weekly\":{\"percent\":-1}}}", "{\"usage\":{\"weekly\":{\"percent\":\"42\"}}}"] {
            XCTAssertThrowsError(try UsageParser.opencode(data(json)))
        }
        XCTAssertThrowsError(try UsageParser.claude(data("{\"extra_usage\":{\"utilization\":10}}")))
    }

    func testExpiredResetDoesNotInventRecovery() throws {
        let window = QuotaWindow(id: "week", kind: .weekly, title: "週間", usedPercent: 100,
                                 resetsAt: Date(timeIntervalSince1970: 100))
        XCTAssertEqual(window.resetText(at: Date(timeIntervalSince1970: 200)), "リセット確認待ち")
        XCTAssertEqual(window.remaining, 0)
        var usage = ServiceUsage(service: .codex)
        usage.windows = [window]
        usage.state = .ready
        XCTAssertTrue(usage.needsWarning(at: Date(timeIntervalSince1970: 200)))
    }

    func testOverageClampsRemainingAndStaleCacheSurvivesRoundtrip() throws {
        let window = QuotaWindow(id: "week", kind: .weekly, title: "週間", usedPercent: 101.1, resetsAt: nil)
        var snapshot = UsageSnapshot()
        snapshot[.claude].windows = [window]
        snapshot[.claude].fetchedAt = Date(timeIntervalSince1970: 123)
        snapshot[.claude].state = .failed
        let restored = try JSONDecoder().decode(UsageSnapshot.self, from: JSONEncoder().encode(snapshot))
        XCTAssertEqual(restored[.claude].windows.first?.remainingText, "0%")
        XCTAssertEqual(restored[.claude].fetchedAt, Date(timeIntervalSince1970: 123))
        XCTAssertTrue(restored[.claude].needsWarning())
        XCTAssertNil(restored[.opencode].fetchedAt)
    }
}
