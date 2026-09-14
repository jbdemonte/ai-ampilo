import Foundation
import Testing
@testable import AIUsageCore

private actor RenewalCredentials: CredentialReading {
    var credential: ClaudeCredential
    init(expired: Bool) {
        credential = .init(accessToken: "fixture-initial", expiresAt: Date().addingTimeInterval(expired ? -3600 : 3600).timeIntervalSince1970 * 1000, scopes: ["user:profile"])
    }
    func read(account: Account) -> ClaudeCredential { credential }
    func replace() { credential.accessToken = "fixture-replaced"; credential.expiresAt = Date().addingTimeInterval(3600).timeIntervalSince1970 * 1000 }
}
private actor ControlledRenewal: CredentialRenewing {
    let credentials: RenewalCredentials
    let result: RenewalResult
    var calls = 0
    init(_ credentials: RenewalCredentials, result: RenewalResult = .succeeded) { self.credentials = credentials; self.result = result }
    func renew(account: Account, binary: String, startingHash: String, rejectedHash: String?) async -> RenewalResult {
        calls += 1
        try? await Task.sleep(for: .milliseconds(100))
        if result == .succeeded { await credentials.replace() }
        return result
    }
}

@Suite struct ReviewRegressionTests {
    @Test(arguments: [true, false]) func renewedCredentialsGetExactlyOneImmediateRead(expired: Bool) async throws {
        let credentials = RenewalCredentials(expired: expired), http = FakeHTTP()
        let renewer = ControlledRenewal(credentials)
        let provider = ClaudeProvider(credentials: credentials, runner: FakeRunner(), http: http)
        let engine = UsageEngine(claude: provider, renewer: renewer)
        let account = Account(provider: .claude)
        var settings = Settings(); settings.claudeBinary = "/usr/bin/true"
        guard case .failure(let error) = await engine.refresh(account: account, settings: settings, reason: .manual) else { Issue.record("Expected invalid credential"); return }
        #expect(error.kind == .tokenInvalid)
        #expect(await http.calls == (expired ? 0 : 1))
        let renewal = Task { await engine.renew(account: account, settings: settings) }
        if case .skipped = await engine.refresh(account: account, settings: settings, reason: .renewed) {} else { Issue.record("Credit was granted before renewal finished") }
        #expect(await renewal.value == .succeeded)
        await http.succeed()
        guard case .success = await engine.refresh(account: account, settings: settings, reason: .renewed) else { Issue.record("Immediate reread was blocked"); return }
        #expect(await http.calls == (expired ? 1 : 2))
        if case .skipped = await engine.refresh(account: account, settings: settings, reason: .renewed) {} else { Issue.record("Retry credit reused") }
        await engine.stop()
    }
    @Test(arguments: [RenewalResult.failed, .deferred]) func unsuccessfulRenewalGrantsNoReadCredit(result: RenewalResult) async {
        let credentials = RenewalCredentials(expired: true), http = FakeHTTP()
        let engine = UsageEngine(claude: ClaudeProvider(credentials: credentials, runner: FakeRunner(), http: http), renewer: ControlledRenewal(credentials, result: result))
        let account = Account(provider: .claude)
        var settings = Settings(); settings.claudeBinary = "/usr/bin/true"
        _ = await engine.refresh(account: account, settings: settings, reason: .manual)
        #expect(await engine.renew(account: account, settings: settings) == result)
        if case .skipped = await engine.refresh(account: account, settings: settings, reason: .renewed) {} else { Issue.record("Failed renewal got read credit") }
        #expect(await http.calls == 0)
        await engine.stop()
    }
    @Test func pendingRenewalKeepsQuotaWithoutReconnectAction() {
        let usage = AccountUsage(accountId: UUID(), windows: [.init(id: "test", label: "test", percent: 87)], source: "test")
        for state in [AccountState.renewing(usage), .renewalPending(usage)] {
            #expect(state.usage?.windows.first?.percent == 87)
            #expect(!state.offersReconnect)
            #expect(state.message != AccountState.tokenInvalid(nil).message)
        }
        #expect(AccountState.tokenInvalid(usage).offersReconnect)
    }
    @Test func onlyDocumentedClaude403CreatesHardPolicyPause() async {
        let documented = Data(#"{"error":{"message":"This credential is only authorized for use with Claude Code"}}"#.utf8)
        #expect(ClaudeProvider.forbiddenError(documented) == .policy)
        for data in [Data("<html>403 Forbidden</html>".utf8), Data(#"{"error":{"message":"Access denied by proxy"}}"#.utf8)] {
            #expect(ClaudeProvider.forbiddenError(data) == .accessDenied)
            let gate = RateGate(provider: .claude, now: { Date(timeIntervalSince1970: 1000) }, jitter: { 0 })
            await gate.finish(error: .init(ClaudeProvider.forbiddenError(data)), interval: 300)
            #expect(await gate.begin(.manual))
        }
        let gate = RateGate(provider: .claude, jitter: { 0 })
        await gate.finish(error: .init(.policy), interval: 300)
        #expect(await gate.begin(.manual) == false)
        await gate.authorizeRenewedRetry()
        #expect(await gate.begin(.renewed) == false)
    }
    @Test func experimentalProvidersNeedExplicitAdditionAndCursorPermission() async {
        #expect(Provider.allCases.filter(\.automaticallyAdded) == [.claude, .codex])
        #expect(Account(provider: .cursor).cursorWebUsageEnabled == nil)
        // No configured CLI, credential lookup or network access may precede consent.
        do { _ = try await CursorProvider().fetch(account: Account(provider: .cursor), binary: "/absent"); Issue.record("Expected consent requirement") }
        catch { #expect(error as? ErrorKind == .permissionRequired) }
    }
    @Test func statuslineFallbackContainsRemainingQuotas() throws {
        let snapshot = try StatuslineSnapshot.capture(Data(#"{"rate_limits":{"five_hour":{"used_percentage":87},"seven_day":{"used_percentage":20}}}"#.utf8))
        let line = snapshot.compactLine()
        #expect(line.contains("13%") && line.contains("80%") && line.contains(" | "))
        #expect(try !StatuslineSnapshot.capture(Data("{}".utf8)).compactLine().isEmpty)
    }
    @Test func userApplicationsAndKeychainDates() {
        let home = URL(fileURLWithPath: "/tmp/fixture-home")
        #expect(AppInstallation.isInApplications(home.appendingPathComponent("Applications/AIUsage.app"), home: home))
        #expect(AppInstallation.isInApplications(URL(fileURLWithPath: "/Applications/AIUsage.app"), home: home))
        #expect(!AppInstallation.isInApplications(home.appendingPathComponent("Applications-other/AIUsage.app"), home: home))
        let raw = #"    "mdat"<timedate>=0x32303236303931343132303030305A00  "20260914120000Z\000""#
        #expect(KeychainReader.modificationDate(in: raw) == QuotaDate.parse("2026-09-14T12:00:00Z"))
        #expect(KeychainReader.modificationDate(in: #""mdat"<timedate>=garbage"#) == nil)
    }
}
