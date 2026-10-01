import Foundation

private final class NoRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

actor ProviderClient {
    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 25
        config.timeoutIntervalForResource = 30
        config.httpCookieStorage = nil
        config.urlCache = nil
        return URLSession(configuration: config, delegate: NoRedirects(), delegateQueue: nil)
    }()
    private var retryAt: [Service: Date] = [:]

    #if DEBUG
    func diagnoseGrokShape() async throws -> String {
        let credential = try Credentials.grokCredential()
        let data = try await request(.grok, url: "https://cli-chat-proxy.grok.com/v1/billing?format=credits", token: credential.token)
        func shape(_ value: Any, depth: Int = 0) -> Any {
            guard depth < 8 else { return "nested" }
            if let object = value as? [String: Any] { return object.mapValues { shape($0, depth: depth + 1) } }
            if let array = value as? [Any] { return array.prefix(1).map { shape($0, depth: depth + 1) } }
            if value is NSNull { return "null" }
            if value is NSNumber { return "number/bool" }
            return "string"
        }
        let safe = shape(try JSONSerialization.jsonObject(with: data))
        return String(decoding: try JSONSerialization.data(withJSONObject: safe, options: [.prettyPrinted, .sortedKeys]), as: UTF8.self)
    }
    #endif

    func fetch(_ service: Service, previous: ServiceUsage, interactive: Bool) async -> ServiceUsage {
        var next = previous
        next.attemptedAt = Date()
        do {
            if let date = retryAt[service], date > Date() { throw UsageError.network(429) }
            let windows: [QuotaWindow]
            switch service {
            case .codex:
                let response = try await CodexRPC.fetch()
                if previous.ownerFingerprint != response.fingerprint { next.windows = []; next.fetchedAt = nil }
                next.ownerFingerprint = response.fingerprint
                windows = try UsageParser.codex(response.data)
                next.source = "Codex app-server"
            case .claude:
                let token = try Credentials.claudeToken(interactive: interactive)
                let fingerprint = Credentials.fingerprint(token)
                if previous.ownerFingerprint != fingerprint { next.windows = []; next.fetchedAt = nil }
                next.ownerFingerprint = fingerprint
                let data = try await request(service, url: "https://api.anthropic.com/api/oauth/usage", token: token)
                windows = try UsageParser.claude(data)
                next.source = "Claude OAuth"
            case .opencode:
                guard let data = try Credentials.read(service: Credentials.service, account: "opencode", interactive: interactive),
                      let token = String(data: data, encoding: .utf8), !token.isEmpty else {
                    throw UsageError.missing("設定でOpenCode GoのAPIキーを入力してください。")
                }
                let fingerprint = Credentials.fingerprint(token)
                if previous.ownerFingerprint != fingerprint { next.windows = []; next.fetchedAt = nil }
                next.ownerFingerprint = fingerprint
                windows = try UsageParser.opencode(await request(service, url: "https://opencode.ai/zen/go/v1/usage", token: token))
                next.source = "OpenCode Go API"
            case .grok:
                let credential = try await GrokCLI.freshCredential()
                let fingerprint = Credentials.fingerprint(credential.accountIdentity ?? credential.token)
                if previous.ownerFingerprint != fingerprint { next.windows = []; next.fetchedAt = nil }
                next.ownerFingerprint = fingerprint
                let data = try await request(service,
                    url: "https://cli-chat-proxy.grok.com/v1/billing?format=credits", token: credential.token)
                do { windows = try GrokSupport.windows(data) }
                catch UsageError.invalidResponse {
                    // Some SuperGrok plans omit the percentage on the CLI proxy.
                    // Read the consumer billing surface rather than inferring full quota.
                    let billing = try await request(service,
                        url: "https://grok.com/grok_api_v2.GrokBuildBilling/GetGrokCreditsConfig",
                        token: credential.token, grokWebBilling: true)
                    windows = try GrokBilling.windows(billing)
                }
                next.source = "SuperGrok（Grok CLI認証）"
            }
            next.windows = windows
            next.fetchedAt = Date()
            next.state = .ready
            next.message = nil
        } catch {
            next.message = (error as? UsageError)?.errorDescription ?? "ネットワークまたは接続情報を確認してください。"
            switch error {
            case UsageError.missing:
                next.markCredentialsMissing()
            case UsageError.authentication, UsageError.keychain: next.state = .needsAuthentication
            default: next.state = .failed
            }
        }
        return next
    }

    private func request(_ service: Service, url: String, token: String, grokWebBilling: Bool = false) async throws -> Data {
        var request = URLRequest(url: URL(string: url)!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("MacAIUsage/0.1", forHTTPHeaderField: "User-Agent")
        if service == .claude { request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta") }
        if service == .grok { request.setValue("xai-grok-cli", forHTTPHeaderField: "x-xai-token-auth") }
        if grokWebBilling {
            request.httpMethod = "POST"
            request.timeoutInterval = 15
            request.httpBody = Data([0, 0, 0, 0, 2, 8, 0])
            request.setValue("application/grpc-web+proto", forHTTPHeaderField: "Content-Type")
            request.setValue("*/*", forHTTPHeaderField: "Accept")
            request.setValue("1", forHTTPHeaderField: "x-grpc-web")
            request.setValue("connect-es/2.1.1", forHTTPHeaderField: "x-user-agent")
            request.setValue("https://grok.com", forHTTPHeaderField: "Origin")
            request.setValue("https://grok.com/?_s=usage", forHTTPHeaderField: "Referer")
        }
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw UsageError.invalidResponse }
        switch response.statusCode {
        case 200:
            guard data.count <= 2_000_000 else { throw UsageError.invalidResponse }
            if grokWebBilling, let status = response.value(forHTTPHeaderField: "grpc-status") {
                try GrokBilling.validateStatus(status)
            }
            return data
        case 401:
            throw UsageError.authentication("認証が切れています。設定から再接続してください。")
        case 403:
            if service == .grok {
                throw UsageError.authentication("SuperGrokの契約とログインを確認してください。grok login で再接続できます。")
            }
            throw UsageError.authentication(service == .opencode ? "このキーでGoの契約を確認できません。ワークスペースと契約を確認してください。" : "使用状況へのアクセス権限がありません。Claude Codeで再ログインしてください。")
        case 429:
            let delay = response.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init) ?? 300
            retryAt[service] = Date().addingTimeInterval(max(60, delay))
            throw UsageError.network(429)
        default: throw UsageError.network(response.statusCode)
        }
    }
}
