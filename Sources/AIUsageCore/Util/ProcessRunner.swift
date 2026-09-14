import Foundation
import Darwin

public struct ProcessResult: Sendable {
    public let stdout: Data
    public let stderr: Data
    public let exitCode: Int32
}
public protocol ProcessRunning: Sendable {
    func run(_ executable: String, arguments: [String], environment: [String: String], timeout: TimeInterval) async throws -> ProcessResult
}
public struct ProcessRunner: ProcessRunning {
    public init() {}
    public func run(_ executable: String, arguments: [String] = [], environment: [String: String] = [:], timeout: TimeInterval = 20) async throws -> ProcessResult {
        let session = try ProcessSession(executable: executable, arguments: arguments, environment: environment)
        defer { session.close() }
        return try await session.collect(timeout: timeout)
    }
    public static func environment(_ overrides: [String: String]) -> [String: String] {
        var env = ["HOME": FileManager.default.homeDirectoryForCurrentUser.path,
                   "USER": NSUserName(), "LOGNAME": NSUserName(),
                   "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "en_US.UTF-8"]
        env.merge(overrides) { _, new in new }
        return env
    }
}

/// Confined to one async caller. All pipe reads are nonblocking, including stderr, to avoid deadlocks.
public final class ProcessSession: @unchecked Sendable {
    private let process = Process()
    private let input = Pipe(), output = Pipe(), errors = Pipe()
    private var buffer = Data(), errorBuffer = Data()
    private var closed = false
    private let limit = 4 * 1024 * 1024
    public init(executable: String, arguments: [String], environment: [String: String]) throws {
        process.executableURL = URL(fileURLWithPath: executable); process.arguments = arguments
        process.environment = ProcessRunner.environment(environment)
        process.currentDirectoryURL = FileManager.default.temporaryDirectory
        process.standardInput = input; process.standardOutput = output; process.standardError = errors
        do { try process.run() } catch { throw ErrorKind.process }
        try? output.fileHandleForWriting.close(); try? errors.fileHandleForWriting.close(); try? input.fileHandleForReading.close()
        for handle in [output.fileHandleForReading, errors.fileHandleForReading] {
            _ = fcntl(handle.fileDescriptor, F_SETFL, O_NONBLOCK)
        }
        _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
    }
    private func drain(_ handle: FileHandle, into data: inout Data) throws {
        var bytes = [UInt8](repeating: 0, count: 16384)
        while true {
            let n = Darwin.read(handle.fileDescriptor, &bytes, bytes.count)
            if n <= 0 { break }
            guard data.count + n <= limit else { throw ErrorKind.malformed }
            data.append(contentsOf: bytes.prefix(n))
        }
    }
    private func pump() throws {
        try drain(output.fileHandleForReading, into: &buffer)
        // Capture only in memory; never interpolate stderr into errors or logs.
        try drain(errors.fileHandleForReading, into: &errorBuffer)
    }
    public func send(_ data: Data) throws {
        do { try input.fileHandleForWriting.write(contentsOf: data) } catch { throw ErrorKind.process }
    }
    public func nextLine(timeout: TimeInterval) async throws -> Data {
        let deadline = ContinuousClock.now.advanced(by: .seconds(timeout))
        while true {
            try Task.checkCancellation(); try pump()
            if let end = buffer.firstIndex(of: 10) {
                let line = Data(buffer[..<end]); buffer.removeSubrange(...end)
                if !line.isEmpty { return line }
            } else if !process.isRunning { throw ErrorKind.process }
            if ContinuousClock.now >= deadline { throw ErrorKind.timeout }
            try await Task.sleep(for: .milliseconds(15))
        }
    }
    public func nextFramedMessage(timeout: TimeInterval) async throws -> Data {
        let deadline = ContinuousClock.now.advanced(by: .seconds(timeout))
        let separator = Data("\r\n\r\n".utf8)
        while true {
            try Task.checkCancellation(); try pump()
            if let boundary = buffer.range(of: separator) {
                guard boundary.lowerBound < 8192 else { throw ErrorKind.malformed }
                let header = String(decoding: buffer[..<boundary.lowerBound], as: UTF8.self)
                guard let lengthLine = header.components(separatedBy: "\r\n").first(where: { $0.lowercased().hasPrefix("content-length:") }),
                      let length = Int(lengthLine.dropFirst(15).trimmingCharacters(in: .whitespaces)),
                      length > 0, length <= limit else { throw ErrorKind.malformed }
                let end = boundary.upperBound + length
                if buffer.count >= end {
                    let data = Data(buffer[boundary.upperBound..<end]); buffer.removeSubrange(..<end); return data
                }
            } else if buffer.count > 8192 { throw ErrorKind.malformed }
            if !process.isRunning { throw ErrorKind.process }
            if ContinuousClock.now >= deadline { throw ErrorKind.timeout }
            try await Task.sleep(for: .milliseconds(15))
        }
    }
    public func collect(timeout: TimeInterval, input data: Data = Data()) async throws -> ProcessResult {
        var sent = 0, inputClosed = false
        _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETFL, O_NONBLOCK)
        let deadline = ContinuousClock.now.advanced(by: .seconds(timeout))
        while process.isRunning {
            try Task.checkCancellation(); try pump()
            if !inputClosed {
                if sent < data.count {
                    let n = data.withUnsafeBytes { bytes in
                        Darwin.write(input.fileHandleForWriting.fileDescriptor, bytes.baseAddress!.advanced(by: sent), min(16384, data.count - sent))
                    }
                    if n > 0 { sent += n }
                    else if n < 0 && errno != EAGAIN && errno != EINTR { throw ErrorKind.process }
                }
                if sent == data.count { try? input.fileHandleForWriting.close(); inputClosed = true }
            }
            if ContinuousClock.now >= deadline { throw ErrorKind.timeout }
            try await Task.sleep(for: .milliseconds(20))
        }
        try pump()
        return .init(stdout: buffer, stderr: errorBuffer, exitCode: process.terminationStatus)
    }
    public func close() {
        guard !closed else { return }; closed = true
        try? input.fileHandleForWriting.close()
        try? output.fileHandleForReading.close(); try? errors.fileHandleForReading.close()
        if process.isRunning {
            process.terminate()
            let process = process
            ProcessCleanup.schedule {
                let deadline = Date().addingTimeInterval(3)
                while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                process.waitUntilExit()
            }
        }
    }
    deinit { close() }
}

public struct BinaryLocator: Sendable {
    private let runner: any ProcessRunning
    public init(runner: any ProcessRunning = ProcessRunner()) { self.runner = runner }
    public func locate(_ provider: Provider, override: String? = nil) async -> String? {
        let fm = FileManager.default, home = FileManager.default.homeDirectoryForCurrentUser.path
        if let override { return fm.isExecutableFile(atPath: override) ? override : nil }
        let names = provider == .cursor ? ["cursor-agent", "agent"] : [provider.binaryName]
        let paths = names.flatMap { name in [home + "/.local/bin/" + name, "/opt/homebrew/bin/" + name, "/usr/local/bin/" + name] }
        if let path = paths.first(where: { fm.isExecutableFile(atPath: $0) }) { return path }
        if let result = try? await runner.run("/bin/zsh", arguments: ["-lc", "command -v " + provider.binaryName], environment: [:], timeout: 5), result.exitCode == 0 {
            let path = String(decoding: result.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            if path.hasPrefix("/"), fm.isExecutableFile(atPath: path) { return path }
        }
        return nil
    }
}
public enum LoginCommand {
    public static func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    public static func shell(account: Account, binary: String) -> String {
        // Clear inherited auth overrides: Terminal may have a different account in its environment.
        let cleared = ["CLAUDE_CONFIG_DIR", "CLAUDE_SECURESTORAGE_CONFIG_DIR", "CODEX_HOME", "ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "CLAUDE_CODE_OAUTH_TOKEN", "OPENAI_API_KEY", "GEMINI_API_KEY", "GOOGLE_API_KEY", "GEMINI_CLI_HOME", "GOOGLE_GENAI_USE_VERTEXAI", "GROK_HOME", "XAI_API_KEY", "GROK_DEPLOYMENT_KEY", "COPILOT_HOME", "COPILOT_GITHUB_TOKEN", "GH_TOKEN", "GITHUB_TOKEN", "CURSOR_API_KEY"]
        let prefix = "/usr/bin/env " + cleared.map { "-u " + $0 }.joined(separator: " ")
        return prefix + " " + account.environment.sorted(by: { $0.key < $1.key }).map { quote($0.key + "=" + $0.value) }.joined(separator: " ") + " " + quote(binary) + (account.provider == .claude ? " auth login" : account.provider == .gemini ? "" : " login")
    }
    public static func appleScript(account: Account, binary: String) -> String {
        let command = shell(account: account, binary: binary).replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        return "tell application \"Terminal\"\nactivate\ndo script \"\(command)\"\nend tell"
    }
}
