import Foundation
import Testing
@testable import AIUsageCore

private var fakeBinary: String { URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("scripts/fake-codex.py").path }
@Suite struct CodexRPCClientTests {
    @Test(arguments: ["normal", "chunks"])
    func readsNDJSONAndIgnoresNotifications(mode: String) async throws {
        let account = Account(provider: .codex, configDirMode: .custom, configDir: URL(fileURLWithPath: "/tmp/" + mode))
        let usage = try await CodexRPCClient(timeout: 3).read(account: account, binary: fakeBinary)
        #expect(usage.windows.count == 3); #expect(usage.providerIdentity.accountId == "fixture-account-123")
    }
    @Test func timeoutIsBounded() async throws {
        let start = Date()
        let account = Account(provider: .codex, configDirMode: .custom, configDir: URL(fileURLWithPath: "/tmp/timeout"))
        do { _ = try await CodexRPCClient(timeout: 0.2).read(account: account, binary: fakeBinary); Issue.record("Expected timeout") }
        catch { #expect((error as? ProviderFailure)?.kind == .timeout || (error as? ErrorKind) == .timeout) }
        #expect(Date().timeIntervalSince(start) < 3)
    }
    @Test func preservesIdentityWhenQuotaReadFails() async throws {
        let account = Account(provider: .codex, configDirMode: .custom, configDir: URL(fileURLWithPath: "/tmp/error"))
        do { _ = try await CodexRPCClient().read(account: account, binary: fakeBinary); Issue.record("Expected RPC failure") }
        catch { #expect((error as? ProviderFailure)?.identity?.email == "fixture@example.invalid") }
    }
    @Test func apiKeyAndLoggedOutStates() async throws {
        let account = Account(provider: .codex, configDirMode: .custom, configDir: URL(fileURLWithPath: "/tmp/apiKey"))
        let usage = try await CodexRPCClient().read(account: account, binary: fakeBinary)
        #expect(usage.windows.isEmpty); #expect(usage.identity?.plan == "apiKey")
        var missing = account; missing.configDir = URL(fileURLWithPath: "/tmp/missing")
        do { _ = try await CodexRPCClient().read(account: missing, binary: fakeBinary); Issue.record("Expected login") }
        catch { #expect((error as? ProviderFailure)?.kind == .needsLogin) }
    }
}
actor FakeCredentials: CredentialReading {
    var value: ClaudeCredential
    init(_ token: String = "fixture-token") {
        value = ClaudeCredential(accessToken: token, expiresAt: Date().addingTimeInterval(3600).timeIntervalSince1970 * 1000, scopes: ["user:profile"])
    }
    func read(account: Account) -> ClaudeCredential { value }
    func change(_ token: String) { value.accessToken = token }
}
struct FakeRunner: ProcessRunning {
    func run(_ executable: String, arguments: [String], environment: [String: String], timeout: TimeInterval) async throws -> ProcessResult {
        let data = arguments == ["--version"] ? Data("2.1.270 (Claude Code)".utf8) : Data(#"{"loggedIn":true,"email":"fixture@example.invalid","orgId":"fixture-org"}"#.utf8)
        return .init(stdout: data, stderr: Data(), exitCode: 0)
    }
}
actor FakeHTTP: HTTPClient {
    var calls = 0
    var status = 401
    func get(_ request: URLRequest) -> HTTPResult { calls += 1; return .init(data: Data(#"{"limits":[]}"#.utf8), status: status) }
    func succeed() { status = 200 }
}
actor FakePTY: PTYRunning {
    let credentials: FakeCredentials
    var calls = 0
    init(_ credentials: FakeCredentials) { self.credentials = credentials }
    func touchAuth(binary: String, environment: [String: String]) async throws { calls += 1; await credentials.change("replacement-token") }
}
@Suite struct DelegatedRefreshTests {
    @Test func futureExpiryDoesNotMakeAnUnchangedTokenValid() async throws {
        let credentials = FakeCredentials(), account = Account(provider: .claude)
        let initial = await credentials.read(account: account)
        #expect(!ClaudeProvider.refreshSucceeded(initial, startingHash: initial.tokenHash, rejectedHash: initial.tokenHash, now: Date()))
        await credentials.change("replacement")
        let new = await credentials.read(account: account)
        #expect(ClaudeProvider.refreshSucceeded(new, startingHash: initial.tokenHash, rejectedHash: initial.tokenHash, now: Date()))
        #expect(!ClaudeProvider.refreshSucceeded(new, startingHash: initial.tokenHash, rejectedHash: new.tokenHash, now: Date()))
    }
    @Test func revokedTokenIsNeverSentTwiceAndExternalRefreshRecovers() async throws {
        let credentials = FakeCredentials(), http = FakeHTTP(), account = Account(provider: .claude)
        let provider = ClaudeProvider(credentials: credentials, runner: FakeRunner(), http: http)
        for _ in 0..<2 {
            do { _ = try await provider.fetch(account: account, binary: "/fixture"); Issue.record("Expected invalid token") }
            catch { #expect((error as? ProviderFailure)?.kind == .tokenInvalid) }
        }
        #expect(await http.calls == 1)
        await credentials.change("replacement"); await http.succeed()
        _ = try await provider.fetch(account: account, binary: "/fixture")
        #expect(await http.calls == 2)
    }
    @Test func PTYRunsForRevokedUnexpiredCredential() async throws {
        let credentials = FakeCredentials(), pty = FakePTY(credentials), account = Account(provider: .claude)
        let hash = await credentials.read(account: account).tokenHash
        let renewer = ClaudeDelegatedRefresh(credentials: credentials, runner: FakeRunner(), pty: pty)
        #expect(await renewer.renew(account: account, binary: "/fixture", startingHash: hash, rejectedHash: hash) == .succeeded)
        #expect(await pty.calls == 1)
        #expect(await renewer.renew(account: account, binary: "/fixture", startingHash: hash, rejectedHash: hash) == .deferred)
    }
    @Test func retryAfterSupportsBothFormats() {
        #expect(ClaudeProvider.retryAfter("900") == 900)
        #expect(ClaudeProvider.retryAfter("Thu, 01 Jan 1970 00:15:00 GMT", now: Date(timeIntervalSince1970: 0)) == 900)
    }
}
@Suite(.enabled(if: ProcessInfo.processInfo.environment["AIUSAGE_INTEGRATION"] == "1")) struct Integration {
    @Test func realCLIsReadOnly() async throws {
        for provider in [Provider.claude, .codex] {
            let account = Account(provider: provider)
            guard let binary = await BinaryLocator().locate(provider) else { continue }
            let reader: any UsageProvider = provider == .claude ? ClaudeProvider() : CodexProvider()
            do {
                let usage = try await reader.fetch(account: account, binary: binary, includeExtras: false, forceIdentity: true)
                #expect(!usage.windows.isEmpty)
                #expect(usage.windows.allSatisfy { $0.percent.isFinite })
            } catch {
                // Do not let the test framework print an error carrying account identity.
                let kind = (error as? ProviderFailure)?.kind ?? error as? ErrorKind ?? .process
                Issue.record("Integration: \(provider.rawValue) \(kind.rawValue)")
            }
        }
    }
}
