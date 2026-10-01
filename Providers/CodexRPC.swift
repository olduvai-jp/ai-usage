import Foundation
import Darwin

enum CodexRPC {
    struct Response: Sendable {
        let data: Data
        let fingerprint: String
    }
    static func executable() -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let paths = [UserDefaults.standard.string(forKey: "codexPath"),
                     "/opt/homebrew/bin/codex", "/usr/local/bin/codex", "\(home)/.local/bin/codex"]
        return paths.compactMap { $0 }.first { FileManager.default.isExecutableFile(atPath: $0) }.map { URL(fileURLWithPath: $0) }
    }
    static func fetch() async throws -> Response {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                do { continuation.resume(returning: try fetchBlocking()) }
                catch { continuation.resume(throwing: error) }
            }
        }
    }
    private static func fetchBlocking() throws -> Response {
        guard let executable = executable() else { throw UsageError.missing("Codex CLIが見つかりません。設定で実行ファイルを選択してください。") }
        let process = Process()
        process.executableURL = executable
        process.arguments = ["app-server"]
        process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:" + (environment["PATH"] ?? "")
        process.environment = environment
        let input = Pipe(), output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let terminate = DispatchWorkItem {
            if process.isRunning { process.terminate() }
        }
        let killTask = DispatchWorkItem {
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 25, execute: terminate)
        DispatchQueue.global().asyncAfter(deadline: .now() + 27, execute: killTask)
        defer {
            terminate.cancel(); killTask.cancel()
            try? input.fileHandleForWriting.close()
            if process.isRunning { process.terminate() }
            try? output.fileHandleForReading.close()
        }
        func send(_ message: [String: Any]) throws {
            var data = try JSONSerialization.data(withJSONObject: message)
            data.append(0x0a)
            try input.fileHandleForWriting.write(contentsOf: data)
        }
        try send(["id": 1, "method": "initialize", "params": ["clientInfo": ["name": "mac_ai_usage", "title": "AI Usage", "version": "0.1.0"]]])
        var buffer = Data()
        var owner: String?
        while true {
            let chunk = output.fileHandleForReading.availableData
            guard !chunk.isEmpty else { throw UsageError.timeout }
            buffer.append(chunk)
            guard buffer.count < 2_000_000 else { throw UsageError.invalidResponse }
            while let end = buffer.firstIndex(of: 0x0a) {
                let line = buffer.subdata(in: buffer.startIndex..<end)
                buffer.removeSubrange(buffer.startIndex...end)
                guard let message = try? UsageParser.object(line), let id = message["id"] as? Int else { continue }
                if message["error"] != nil {
                    throw UsageError.authentication("Codexの使用状況を取得できません。codex login でChatGPTへの接続を確認してください。")
                }
                guard let result = message["result"] as? [String: Any] else { throw UsageError.invalidResponse }
                switch id {
                case 1:
                    try send(["method": "initialized", "params": [:]])
                    try send(["id": 2, "method": "account/read", "params": ["refreshToken": false]])
                case 2:
                    guard let account = result["account"] as? [String: Any], account["type"] as? String == "chatgpt" else {
                        throw UsageError.missing("CodexをChatGPTの定額プランでログインしてください。APIキーは対象外です。")
                    }
                    let identity = (account["email"] as? String ?? "") + ":" + (account["planType"] as? String ?? "")
                    owner = Credentials.fingerprint(identity)
                    try send(["id": 3, "method": "account/rateLimits/read", "params": [:]])
                case 3:
                    guard let owner else { throw UsageError.invalidResponse }
                    return Response(data: try JSONSerialization.data(withJSONObject: result), fingerprint: owner)
                default: break
                }
            }
        }
    }
}
