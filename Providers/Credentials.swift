import Foundation
import Security
import CryptoKit
import LocalAuthentication

enum Credentials {
    static let service = "jp.olduvai.MacAIUsage.credentials"
    static func read(service: String, account: String? = nil, interactive: Bool) throws -> Data? {
        var query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                  kSecAttrService as String: service,
                                  kSecReturnData as String: true,
                                  kSecMatchLimit as String: kSecMatchLimitOne]
        if let account { query[kSecAttrAccount as String] = account }
        let context = LAContext()
        context.interactionNotAllowed = !interactive
        query[kSecUseAuthenticationContext as String] = context
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw UsageError.keychain(status) }
        return result as? Data
    }
    static func saveGoKey(_ key: String) throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                  kSecAttrService as String: service,
                                  kSecAttrAccount as String: "opencode"]
        let data = Data(key.utf8)
        var status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var new = query
            new[kSecValueData as String] = data
            new[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            status = SecItemAdd(new as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw UsageError.keychain(status) }
    }
    static func fingerprint(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    static func claudeToken(interactive: Bool) throws -> String {
        // Read Claude's own record each time. Never modify or refresh its credentials.
        let data: Data
        if let stored = try read(service: "Claude Code-credentials", interactive: interactive) {
            data = stored
        } else {
            let home = FileManager.default.homeDirectoryForCurrentUser
            let path = home.appendingPathComponent(".claude/.credentials.json")
            guard FileManager.default.fileExists(atPath: path.path) else {
                throw UsageError.missing("Claude Codeでログイン後、「接続確認」を押してください。")
            }
            data = try Data(contentsOf: path)
        }
        guard let root = try? UsageParser.object(data) else { throw UsageError.invalidResponse }
        guard let oauth = root["claudeAiOauth"] as? [String: Any] else {
            throw UsageError.missing("Claude Codeの定額プランでログインすると利用できます。")
        }
        guard
              let token = oauth["accessToken"] as? String, !token.isEmpty else {
            throw UsageError.missing("Claude Codeの定額プランでログインすると利用できます。")
        }
        if let expiry = UsageParser.number(oauth["expiresAt"]), expiry / 1000 <= Date().timeIntervalSince1970 {
            throw UsageError.authentication("Claudeの認証期限が切れています。Claude Codeを起動して認証を更新後、再接続してください。")
        }
        if let scopes = oauth["scopes"] as? [String], !scopes.contains("user:profile") {
            throw UsageError.authentication("利用枠を読む権限がありません。setup-tokenではなくClaude Codeでログインしてください。")
        }
        return token
    }
    static func grokCredential() throws -> GrokSupport.Credential {
        let custom = ProcessInfo.processInfo.environment["GROK_HOME"]
        let home = custom.flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".grok")
        let path = home.appendingPathComponent("auth.json")
        guard FileManager.default.fileExists(atPath: path.path) else {
            throw UsageError.missing("grok login でSuperGrokにログイン後、接続確認してください。")
        }
        // Read only; Grok CLI owns token refresh and its authentication file.
        return try GrokSupport.credential(Data(contentsOf: path))
    }
}
