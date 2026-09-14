import Foundation
import Darwin
import PTYBridge

public protocol PTYRunning: Sendable { func touchAuth(binary: String, environment: [String: String]) async throws }
public struct PTYRunner: PTYRunning {
    public init() {}
    public func touchAuth(binary: String, environment: [String: String]) async throws {
        var environment = ProcessRunner.environment(environment)
        environment["TERM"] = "xterm-256color"; environment["COLUMNS"] = "120"; environment["LINES"] = "40"
        let env = environment.map { strdup($0.key + "=" + $0.value) } + [nil]
        let args = [strdup(binary), nil]
        defer { env.forEach { free($0) }; args.forEach { free($0) } }
        var fd: Int32 = -1
        let pid = args.withUnsafeBufferPointer { argv in
            env.withUnsafeBufferPointer { envp in
                aiusage_spawn_pty(binary, argv.baseAddress!, envp.baseAddress!, FileManager.default.temporaryDirectory.path, &fd)
            }
        }
        guard pid > 0 else { throw ErrorKind.process }
        defer {
            let descriptor = fd
            // This dedicated worker also runs during Swift task cancellation, reaping the process group.
            ProcessCleanup.schedule { aiusage_stop_pty(pid, descriptor) }
        }
        func writeCommand(_ command: String) throws {
            let data = Data(command.utf8)
            let n = data.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
            if n != data.count { throw ErrorKind.process }
        }
        let start = ContinuousClock.now
        var bytes = [UInt8](repeating: 0, count: 8192), text = "", sent = false
        var sentAt = ContinuousClock.now
        while ContinuousClock.now - start < .seconds(55) {
            try Task.checkCancellation()
            let n = Darwin.read(fd, &bytes, bytes.count)
            if n > 0 { text += String(decoding: bytes.prefix(n), as: UTF8.self); text = String(text.suffix(32768)) }
            let plain = text.replacingOccurrences(of: #"\x1b\[[0-?]*[ -/]*[@-~]"#, with: "", options: .regularExpression)
            if !sent && (plain.contains("❯") || plain.contains("\n> ")) {
                try writeCommand("/status\r"); sent = true; sentAt = .now
            }
            if !sent && ContinuousClock.now - start > .seconds(20) { throw ErrorKind.timeout }
            if sent && ContinuousClock.now - sentAt >= .seconds(10) {
                try writeCommand("/exit\r")
                try await Task.sleep(for: .seconds(5)); return
            }
            if n == 0 { throw ErrorKind.process }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw ErrorKind.timeout
    }
}
public enum RenewalResult: Sendable { case succeeded, failed, deferred }
public protocol CredentialRenewing: Sendable {
    func renew(account: Account, binary: String, startingHash: String, rejectedHash: String?) async -> RenewalResult
}
public actor ClaudeDelegatedRefresh: CredentialRenewing {
    private let credentials: any CredentialReading
    private let runner: any ProcessRunning
    private let pty: any PTYRunning
    private var lastAttempt: [UUID: Date] = [:]
    private var running: Set<UUID> = []
    public init(credentials: any CredentialReading = KeychainReader(), runner: any ProcessRunning = ProcessRunner(), pty: any PTYRunning = PTYRunner()) {
        self.credentials = credentials; self.runner = runner; self.pty = pty
    }
    public func renew(account: Account, binary: String, startingHash: String, rejectedHash: String?) async -> RenewalResult {
        guard !running.contains(account.id), running.count < 2,
              lastAttempt[account.id].map({ Date().timeIntervalSince($0) >= 600 }) ?? true else { return .deferred }
        running.insert(account.id); lastAttempt[account.id] = Date()
        defer { running.remove(account.id) }
        func success() async -> Bool {
            guard let credential = try? await credentials.read(account: account) else { return false }
            return ClaudeProvider.refreshSucceeded(credential, startingHash: startingHash, rejectedHash: rejectedHash, now: Date())
        }
        // A CLI session may already have refreshed the credential while this job was being scheduled.
        if await success() { return .succeeded }
        _ = try? await runner.run(binary, arguments: ["auth", "status", "--json"], environment: account.environment, timeout: 30)
        guard !Task.isCancelled else { return .deferred }
        if await success() { return .succeeded }
        do { try await pty.touchAuth(binary: binary, environment: account.environment) } catch {}
        guard !Task.isCancelled else { return .deferred }
        return await success() ? .succeeded : .failed
    }
}
