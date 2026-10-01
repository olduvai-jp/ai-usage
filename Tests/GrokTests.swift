import XCTest
@testable import UsageCore

final class GrokTests: XCTestCase {
    private func data(_ text: String) -> Data { Data(text.utf8) }

    func testExpiredAccessTokenUsesCLIRefreshThenReloadsCredentials() async throws {
        let now = Date()
        let old = GrokSupport.Credential(token: "old", expiresAt: now.addingTimeInterval(-10))
        let renewed = GrokSupport.Credential(token: "renewed", expiresAt: now.addingTimeInterval(21600))
        var ranCLI = false
        let result = try await GrokSupport.refreshIfNeeded(old, now: now, runCLI: { ranCLI = true }, reload: {
            XCTAssertTrue(ranCLI)
            return renewed
        })
        XCTAssertTrue(ranCLI)
        XCTAssertEqual(result.token, renewed.token)
    }

    func testFreshAccessTokenDoesNotStartCLI() async throws {
        let credential = GrokSupport.Credential(token: "fresh", expiresAt: Date().addingTimeInterval(3600))
        let result = try await GrokSupport.refreshIfNeeded(credential, runCLI: { XCTFail("Unnecessary CLI call") }, reload: {
            XCTFail("Unnecessary credential reload")
            return credential
        })
        XCTAssertEqual(result.token, credential.token)
    }

    func testUnsuccessfulCLIRefreshIsNotMisclassifiedAsLoginRevocation() async {
        let credential = GrokSupport.Credential(token: "expired", expiresAt: Date().addingTimeInterval(-10))
        do {
            _ = try await GrokSupport.refreshIfNeeded(credential, runCLI: {}, reload: { credential })
            XCTFail("Unchanged expired credential must not be used")
        } catch {
            guard case UsageError.refreshFailed = error else { return XCTFail("Expected refresh failure, not authentication revocation") }
        }
    }

    func testAccountIdentitySurvivesAccessTokenRotation() throws {
        let old = try GrokSupport.credential(data("""
        {"https://auth.x.ai::test":{"key":"synthetic-old","user_id":"user-a"}}
        """))
        let renewed = try GrokSupport.credential(data("""
        {"https://auth.x.ai::test":{"key":"synthetic-new","user_id":"user-a"}}
        """))
        let different = try GrokSupport.credential(data("""
        {"https://auth.x.ai::test":{"key":"synthetic-other","user_id":"user-b"}}
        """))
        XCTAssertNotNil(old.accountIdentity)
        XCTAssertEqual(old.accountIdentity, renewed.accountIdentity)
        XCTAssertNotEqual(old.accountIdentity, different.accountIdentity)
    }

    private func varint(_ value: UInt64) -> [UInt8] {
        var rest = value
        var result: [UInt8] = []
        repeat {
            let byte = UInt8(rest & 127)
            rest >>= 7
            result.append(byte | (rest > 0 ? 128 : 0))
        } while rest > 0
        return result
    }
    private func message(_ number: UInt8, _ bytes: [UInt8]) -> [UInt8] {
        [number << 3 | 2] + varint(UInt64(bytes.count)) + bytes
    }
    private func frame(_ payload: [UInt8], flag: UInt8 = 0) -> [UInt8] {
        [flag] + (0..<4).reversed().map { UInt8(truncatingIfNeeded: payload.count >> ($0 * 8)) } + payload
    }
    private func billing(_ config: [UInt8], status: String = "0") -> Data {
        Data(frame(message(1, config)) + frame(Array("grpc-status: \(status)\r\n".utf8), flag: 128))
    }

    func testConsumerBillingReadsOnlyTopLevelUsagePercentage() throws {
        // config.creditUsagePercent = float32(25); nested product usage is not the account quota.
        let response = billing([13, 0, 0, 200, 65] + message(7, [13, 0, 0, 72, 66]))
        XCTAssertEqual(try GrokBilling.windows(response).first?.remaining, 75)
        XCTAssertThrowsError(try GrokBilling.windows(billing(message(7, [13, 0, 0, 72, 66]))))
    }

    func testConsumerBillingImplicitZeroRequiresActiveCurrentPeriod() throws {
        let start: UInt64 = 1_800_000_000
        let period = [UInt8(8), 1] + message(2, [8] + varint(start)) + message(3, [8] + varint(start + 604800))
        let response = billing(message(8, period))
        let windows = try GrokBilling.windows(response, now: Date(timeIntervalSince1970: Double(start + 100)))
        XCTAssertEqual(windows.first?.remaining, 100)
        XCTAssertEqual(windows.first?.kind, .weekly)
        XCTAssertThrowsError(try GrokBilling.windows(response, now: Date(timeIntervalSince1970: Double(start - 1))))
        XCTAssertThrowsError(try GrokBilling.windows(response, now: Date(timeIntervalSince1970: Double(start + 604800))))
        XCTAssertThrowsError(try GrokBilling.windows(billing([])))
    }

    func testConsumerBillingRejectsRPCFailuresAndBrokenWireData() {
        let percent: [UInt8] = [13, 0, 0, 200, 65]
        XCTAssertThrowsError(try GrokBilling.windows(billing(percent, status: "16"))) { error in
            guard case UsageError.authentication = error else { return XCTFail("Expected authentication error") }
        }
        XCTAssertThrowsError(try GrokBilling.windows(billing(percent, status: "13")))
        XCTAssertThrowsError(try GrokBilling.windows(billing(percent + percent)))
        XCTAssertThrowsError(try GrokBilling.windows(billing([13, 0, 0, 192, 127]))) // NaN
        let valid = billing(percent)
        for count in [0, 1, 4, 8, valid.count - 1] {
            XCTAssertThrowsError(try GrokBilling.windows(Data(valid.prefix(count))))
        }
        XCTAssertThrowsError(try GrokBilling.windows(billing([10, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255])))
    }

    func testWeeklyQuotaUsesWholePeriodNotTimeUntilReset() throws {
        let windows = try GrokSupport.windows(data("""
        {"config":{"creditUsagePercent":24.5,
        "currentPeriod":{"start":"2026-09-28T00:00:00Z","end":"2026-10-05T00:00:00Z"},
        "billingPeriodStart":"2026-09-01T00:00:00Z","billingPeriodEnd":"2026-10-01T00:00:00Z"}}
        """))
        XCTAssertEqual(windows.first?.kind, .weekly)
        XCTAssertEqual(windows.first?.remainingText, "75%")
        XCTAssertEqual(windows.first?.resetsAt, UsageParser.date("2026-10-05T00:00:00Z"))
    }

    func testMonthlyFallbackAndUnknownPeriodDoNotInventWeeklyQuota() throws {
        let monthly = try GrokSupport.windows(data("""
        {"config":{"creditUsagePercent":0,"billingPeriodStart":"2026-09-01T00:00:00Z",
        "billingPeriodEnd":"2026-10-01T00:00:00Z"}}
        """))
        XCTAssertEqual(monthly.first?.kind, .monthly)
        XCTAssertEqual(monthly.first?.remaining, 100)
        let unknown = try GrokSupport.windows(data("""
        {"config":{"creditUsagePercent":70,"currentPeriod":{"end":"2026-10-05T00:00:00Z"},
        "billingPeriodStart":"2026-09-28T00:00:00Z"}}
        """))
        XCTAssertEqual(unknown.first?.kind, .current)
        XCTAssertEqual(unknown.first?.remaining, 30)
    }

    func testMissingQuotaNeverUsesOnDemandSpendingOrAssumesZero() {
        for json in ["{}", "{\"config\":{}}", "{\"config\":{\"creditUsagePercent\":true}}",
                     "{\"config\":{\"creditUsagePercent\":-1}}", "{\"config\":{\"creditUsagePercent\":\"30\"}}",
                     "{\"config\":{\"onDemandCap\":{\"val\":100},\"onDemandUsed\":{\"val\":10}}}"] {
            XCTAssertThrowsError(try GrokSupport.windows(data(json)))
        }
    }

    func testCredentialsPreferOIDCAndPreserveExpiry() throws {
        let credential = try GrokSupport.credential(data("""
        {"https://accounts.x.ai/sign-in":{"key":"synthetic-legacy"},
        "https://auth.x.ai::test":{"key":"synthetic-oidc","expires_at":"2026-10-01T00:00:00Z"},
        "unrelated":{"key":"synthetic-ignored"}}
        """))
        XCTAssertEqual(credential.token, "synthetic-oidc")
        XCTAssertEqual(credential.expiresAt, UsageParser.date("2026-10-01T00:00:00Z"))
    }

    func testMissingLoginIsUnconfiguredAndMalformedLoginIsAnError() throws {
        for json in ["{}", "{\"https://auth.x.ai::test\":{\"key\":\"\"}}"] {
            XCTAssertThrowsError(try GrokSupport.credential(data(json))) { error in
                guard case UsageError.missing = error else { return XCTFail("Expected missing login") }
            }
        }
        XCTAssertThrowsError(try GrokSupport.credential(data("""
        {"https://auth.x.ai::test":{"key":"synthetic","expires_at":"invalid"}}
        """)))
        XCTAssertThrowsError(try GrokSupport.credential(data("""
        {"https://auth.x.ai::test":{"key":"synthetic","principal_type":"team"}}
        """)))
    }

    func testOldSnapshotGainsGrokWithoutLosingOtherServices() throws {
        var old = UsageSnapshot()
        old.services.removeAll { $0.service == .grok }
        old[.codex].state = .ready
        let restored = try JSONDecoder().decode(UsageSnapshot.self, from: JSONEncoder().encode(old))
        XCTAssertFalse(restored[.grok].isConfigured)
        var updated = restored
        updated[.grok].state = .ready
        XCTAssertEqual(updated.configuredServices.map(\.service), [.codex, .grok])
    }
}
