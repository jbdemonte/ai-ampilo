import Foundation
import Testing
@testable import AIUsageCore

@Suite struct StatuslineTests {
    @Test func onlyQuotaFieldsArePersistedAndScopedWindowsSurvive() throws {
        let data = Data(#"{"session_id":"private-session","cwd":"/private/project","api_key":"must-not-be-cached","rate_limits":{"five_hour":{"used_percentage":25,"resets_at":2000000000}}}"#.utf8)
        let snapshot = try StatuslineSnapshot.capture(data)
        let encoded = String(decoding: try JSONEncoder().encode(snapshot), as: UTF8.self)
        #expect(!encoded.contains("private")); #expect(!encoded.contains("must-not"))
        let old = AccountUsage(accountId: UUID(), windows: [
            .init(id: "claude:session::", label: "Session", percent: 20),
            .init(id: "claude:weekly_scoped:fable:", label: "Fable", percent: 80)], fetchedAt: Date().addingTimeInterval(-100), source: "claude-oauth-usage")
        let merged = snapshot.merging(into: old)
        #expect(merged.windows.count == 2); #expect(merged.windows[0].percent == 25)
        #expect(merged.windows[1].percent == 80); #expect(merged.fetchedAt == old.fetchedAt)
    }
    @Test func installationAndRemovalPreserveSettingsAndUserEdits() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = AppPaths(root: root), config = root.appendingPathComponent("config")
        try FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)
        let settingsURL = config.appendingPathComponent("settings.json")
        let original: [String: Any] = ["theme": "dark", "statusLine": ["type": "command", "command": "cat >/dev/null; printf 'previous'", "padding": 2]]
        try JSONSerialization.data(withJSONObject: original).write(to: settingsURL)
        let account = Account(provider: .claude, configDirMode: .custom, configDir: config)
        let installation = StatuslineInstallation(paths: paths)
        try installation.install(account: account, helper: URL(fileURLWithPath: "/usr/bin/true"))
        var installed = try JSONSerialization.jsonObject(with: Data(contentsOf: settingsURL)) as! [String: Any]
        #expect(installed["theme"] as? String == "dark")
        #expect((installed["statusLine"] as? [String: Any])?["padding"] as? Int == 2)
        try installation.uninstall(account: account)
        let restored = try JSONSerialization.jsonObject(with: Data(contentsOf: settingsURL)) as! [String: Any]
        #expect((restored["statusLine"] as? [String: Any])?["command"] as? String == "cat >/dev/null; printf 'previous'")
        try installation.install(account: account, helper: URL(fileURLWithPath: "/usr/bin/true"))
        installed["statusLine"] = ["type": "command", "command": "printf 'user changed this'"]
        try JSONSerialization.data(withJSONObject: installed).write(to: settingsURL)
        try installation.uninstall(account: account)
        let retained = try JSONSerialization.jsonObject(with: Data(contentsOf: settingsURL)) as! [String: Any]
        #expect((retained["statusLine"] as? [String: Any])?["command"] as? String == "printf 'user changed this'")
    }
}
@Suite struct ProcessTests {
    @Test func largeInputAndOutputDoNotDeadlock() async throws {
        let session = try ProcessSession(executable: "/usr/bin/python3", arguments: ["-c", "import sys; sys.stdout.write('x'*100000); sys.stdout.flush(); sys.stderr.write('y'*100000); sys.stderr.flush(); data=sys.stdin.buffer.read(); print(len(data))"], environment: [:])
        defer { session.close() }
        let result = try await session.collect(timeout: 5, input: Data(repeating: 65, count: 200000))
        #expect(result.exitCode == 0); #expect(result.stderr.suffix(100000) == Data(repeating: 121, count: 100000))
        #expect(String(decoding: result.stdout.suffix(7), as: UTF8.self) == "200000\n")
    }
    @Test func cancellationReturnsPromptly() async throws {
        let task = Task { try await ProcessRunner().run("/bin/sleep", arguments: ["60"], timeout: 60) }
        try await Task.sleep(for: .milliseconds(100)); let start = Date(); task.cancel()
        do { _ = try await task.value; Issue.record("Expected cancellation") } catch { #expect(error is CancellationError) }
        #expect(Date().timeIntervalSince(start) < 1)
    }
    @Test func sanitizedEnvironmentKeepsUserAndDropsAuthOverrides() {
        let env = ProcessRunner.environment([:])
        #expect(env["USER"] == NSUserName()); #expect(env["LOGNAME"] == NSUserName())
        for name in ["ANTHROPIC_API_KEY", "CLAUDE_CODE_OAUTH_TOKEN", "CLAUDE_CONFIG_DIR", "CODEX_HOME"] { #expect(env[name] == nil) }
    }
}
