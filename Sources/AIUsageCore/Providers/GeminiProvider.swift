import Foundation
import Darwin
import PTYBridge

public enum GeminiQuotaParser {
    public static func plain(_ text: String) -> String {
        text.replacingOccurrences(of: #"\x1b\][^\x07]*(?:\x07|\x1b\\)"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\x1b\[[0-?]*[ -/]*[@-~]"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: "\r", with: "\n")
    }
    public static func map(_ transcript: String, now: Date = Date()) throws -> [UsageWindow] {
        let text = plain(transcript)
        // Restrict matches to the account quota block; context/session token percentages are not quotas.
        let pooled = try NSRegularExpression(pattern: #"(?:(\d+(?:\.\d+)?)% used(?: \(Limit resets in ([^\)]+)\))?|Limit reached(?:, resets in ([^\n]+))?)"#)
        let matches = pooled.matches(in: text, range: NSRange(text.startIndex..., in: text)).filter { match in
            guard let range = Range(match.range, in: text) else { return false }
            return text[range.upperBound...].prefix(160).contains("Usage limit:")
        }
        if let match = matches.last {
            func value(_ i: Int) -> String? { guard let r = Range(match.range(at: i), in: text) else { return nil }; return String(text[r]) }
            let used = value(1).flatMap(Double.init) ?? 100
            guard used.isFinite, (0...100).contains(used) else { throw ErrorKind.malformed }
            return [.init(id: "gemini:daily", label: L("Quota quotidien"), percent: used,
                          resetsAt: relativeReset(value(2) ?? value(3), now: now), durationMinutes: 1440, isActive: true)]
        }
        // Older CLI releases display one daily quota per model: "gemini-…  …  97.5% (Resets in 2h 10m)".
        let regex = try NSRegularExpression(pattern: #"(?m)(gemini-[A-Za-z0-9.\-]+)[^\n%]*?([0-9]+(?:\.[0-9]+)?)%\s*\((?:Quota resets in|Resets in|resets in) ([^\)]+)\)"#)
        var windows: [String: UsageWindow] = [:], order: [String] = []
        for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            let parts = (1...3).compactMap { Range(match.range(at: $0), in: text).map { String(text[$0]) } }
            guard parts.count == 3, let remaining = Double(parts[1]), (0...100).contains(remaining) else { throw ErrorKind.malformed }
            if windows[parts[0]] == nil { order.append(parts[0]) }
            windows[parts[0]] = .init(id: "gemini:" + parts[0], label: parts[0], percent: 100 - remaining, resetsAt: relativeReset(parts[2], now: now), durationMinutes: 1440)
        }
        guard !order.isEmpty else { throw ErrorKind.quotaUnavailable }
        return order.compactMap { windows[$0] }
    }
    static func relativeReset(_ value: String?, now: Date) -> Date? {
        guard let value, let regex = try? NSRegularExpression(pattern: #"(\d+)\s*(d|h|m|s)"#) else { return nil }
        var seconds: Double = 0
        for match in regex.matches(in: value, range: NSRange(value.startIndex..., in: value)) {
            guard let n = Range(match.range(at: 1), in: value), let u = Range(match.range(at: 2), in: value), let count = Double(value[n]) else { continue }
            seconds += count * (["d": 86400.0, "h": 3600, "m": 60, "s": 1][String(value[u])] ?? 0)
        }
        return seconds > 0 ? now.addingTimeInterval(seconds) : nil
    }
}
public protocol GeminiQuotaReading: Sendable { func read(binary: String, environment: [String: String]) async throws -> String }
public struct GeminiTerminalReader: GeminiQuotaReading {
    public init() {}
    public func read(binary: String, environment: [String: String]) async throws -> String {
        var environment = ProcessRunner.environment(environment)
        environment["TERM"] = "xterm-256color"; environment["COLUMNS"] = "160"; environment["LINES"] = "60"; environment["NO_COLOR"] = "1"
        let env = environment.map { strdup($0.key + "=" + $0.value) } + [nil]
        let arguments: [String] = [binary, "--screen-reader", "--skip-trust", "--model", "auto"]
        let args = arguments.map { strdup($0) } + [nil]
        defer { env.forEach { free($0) }; args.forEach { free($0) } }
        let workspace = FileManager.default.temporaryDirectory.appendingPathComponent("aiusage-gemini-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        var fd: Int32 = -1
        let pid = args.withUnsafeBufferPointer { argv in env.withUnsafeBufferPointer { envp in
            aiusage_spawn_pty(binary, argv.baseAddress!, envp.baseAddress!, workspace.path, &fd)
        } }
        guard pid > 0 else { try? FileManager.default.removeItem(at: workspace); throw ErrorKind.process }
        defer { let descriptor = fd; ProcessCleanup.schedule {
            aiusage_stop_pty(pid, descriptor); try? FileManager.default.removeItem(at: workspace)
        } }
        func send(_ command: String) throws {
            let bytes = Data(command.utf8)
            guard bytes.withUnsafeBytes({ Darwin.write(fd, $0.baseAddress, $0.count) }) == bytes.count else { throw ErrorKind.process }
        }
        let start = ContinuousClock.now
        var bytes = [UInt8](repeating: 0, count: 16384), output = "", stage = 0
        var sentAt = ContinuousClock.now
        while ContinuousClock.now - start < .seconds(35) {
            try Task.checkCancellation()
            let n = Darwin.read(fd, &bytes, bytes.count)
            if n > 0 { output += String(decoding: bytes.prefix(n), as: UTF8.self) }
            guard output.utf8.count < 2 * 1024 * 1024 else { throw ErrorKind.malformed }
            let text = GeminiQuotaParser.plain(output)
            if stage == 0 {
                if text.contains("Login with Google") || text.contains("Sign in with Google") || text.contains("How would you like to authenticate") { throw ErrorKind.needsLogin }
                if text.contains("Type your message") || text.contains("Type your prompt") || text.range(of: #"(?m)^\s*>\s*$"#, options: .regularExpression) != nil {
                    try send("/stats\r"); stage = 1; sentAt = .now; output = ""
                }
            } else if stage == 1, ContinuousClock.now - sentAt > .seconds(3) {
                try send("/stats model\r"); stage = 2; sentAt = .now
            } else if stage == 2, ContinuousClock.now - sentAt > .seconds(2), (try? GeminiQuotaParser.map(text)) != nil {
                return text
            }
            if n == 0 { throw ErrorKind.quotaUnavailable }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw ErrorKind.quotaUnavailable
    }
}
public struct GeminiProvider: UsageProvider {
    private let reader: any GeminiQuotaReading
    public init(reader: any GeminiQuotaReading = GeminiTerminalReader()) { self.reader = reader }
    public func fetch(account: Account, binary: String, includeExtras: Bool = false, forceIdentity: Bool = false) async throws -> AccountUsage {
        let text = try await reader.read(binary: binary, environment: account.environment)
        let plain = GeminiQuotaParser.plain(text)
        let regex = try NSRegularExpression(pattern: #"Signed in with Google \(([^\s\)]+@[^\s\)]+)\)"#)
        let match = regex.matches(in: plain, range: NSRange(plain.startIndex..., in: plain)).last
        let email = match.flatMap { Range($0.range(at: 1), in: plain) }.map { String(plain[$0]) }
        return .init(accountId: account.id, identity: .init(email: email), windows: try GeminiQuotaParser.map(plain), source: "gemini-cli-stats", providerIdentity: .init(email: email))
    }
}
