import Foundation
import Darwin

enum GrokCLI {
    static func freshCredential() async throws -> GrokSupport.Credential {
        let credential = try Credentials.grokCredential()
        return try await GrokSupport.refreshIfNeeded(credential, runCLI: refreshAuthentication,
                                                     reload: Credentials.grokCredential)
    }

    /// `models` exercises the CLI's own token refresh without starting a conversation or login flow.
    private static func refreshAuthentication() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            DispatchQueue.global(qos: .utility).async {
                do {
                    let home = FileManager.default.homeDirectoryForCurrentUser
                    let paths = [home.appendingPathComponent(".grok/bin/grok").path,
                                 "/opt/homebrew/bin/grok", "/usr/local/bin/grok"]
                    guard let executable = paths.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
                        throw UsageError.refreshFailed("Grok CLIが見つからないため認証を自動更新できません。Grok CLIのインストールを確認してください。")
                    }
                    let process = Process()
                    process.executableURL = URL(fileURLWithPath: executable)
                    process.arguments = ["models"]
                    process.currentDirectoryURL = home
                    process.standardInput = FileHandle.nullDevice
                    process.standardOutput = FileHandle.nullDevice
                    process.standardError = FileHandle.nullDevice
                    try process.run()
                    let terminate = DispatchWorkItem { if process.isRunning { process.terminate() } }
                    let killTask = DispatchWorkItem { if process.isRunning { kill(process.processIdentifier, SIGKILL) } }
                    DispatchQueue.global().asyncAfter(deadline: .now() + 15, execute: terminate)
                    DispatchQueue.global().asyncAfter(deadline: .now() + 17, execute: killTask)
                    defer { terminate.cancel(); killTask.cancel() }
                    process.waitUntilExit()
                    // The CLI can print an auth warning while successfully refreshing in the background.
                    // The reloaded credential, not its output or exit code, proves whether renewal succeeded.
                    continuation.resume()
                } catch { continuation.resume(throwing: error) }
            }
        }
    }
}
