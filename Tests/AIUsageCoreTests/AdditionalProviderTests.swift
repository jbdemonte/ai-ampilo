import Foundation
import Testing
@testable import AIUsageCore

private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
    try JSONDecoder().decode(type, from: Data(json.utf8))
}
private var quotaFixture: String {
    URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("scripts/fake-quota-cli.py").path
}

@Suite struct AdditionalQuotaTests {
    @Test func grokPrefersCurrentQuotaAndHandlesLegacyZero() throws {
        let quota = try decode(GrokQuotaResponse.self, #"{"config":{"creditUsagePercent":87,"monthlyLimit":{"val":100},"used":{"val":1},"currentPeriod":{"type":"USAGE_PERIOD_TYPE_WEEKLY","end":"2030-01-01T00:00:00Z"}},"subscription_tier":"SuperGrok"}"#)
        let window = try #require(quota.windows().first)
        #expect(window.remainingPercent(at: Date()) == 13)
        #expect(window.durationMinutes == 10080)
        #expect(window.resetsAt == QuotaDate.parse("2030-01-01T00:00:00Z"))
        let legacy = try decode(GrokQuotaResponse.self, #"{"config":{"monthlyLimit":{"val":2000},"used":{}}}"#)
        #expect(try legacy.windows().first?.percent == 0)
    }
    @Test func copilotSkipsUnlimitedAndKeepsExhaustion() throws {
        let quota = try decode(CopilotQuotaResponse.self, #"{"quotaSnapshots":{"completions":{"isUnlimitedEntitlement":true,"remainingPercentage":100},"premium_interactions":{"entitlementRequests":300,"usedRequests":330},"chat":{"remainingPercentage":13}}}"#)
        let windows = try quota.windows()
        #expect(windows.map(\.id) == ["copilot:chat", "copilot:premium_interactions"])
        #expect(windows.map { $0.remainingPercent(at: Date()) } == [13, 0])
    }
    @Test func cursorPercentUnitsAndSpendingCaps() throws {
        let quota = try decode(CursorQuotaResponse.self, #"{"individualUsage":{"plan":{"enabled":true,"autoPercentUsed":0.5,"apiPercentUsed":87},"overall":{"enabled":true,"used":50,"limit":100}},"onDemand":{"used":9999,"limit":10000}}"#)
        let windows = try quota.windows()
        #expect(windows.map(\.percent) == [0.5, 87, 50])
        #expect(windows.map(\.id) == ["cursor:auto", "cursor:api", "cursor:overall"])
        let pooled = try decode(CursorQuotaResponse.self, #"{"teamUsage":{"pooled":{"used":20,"limit":200}}}"#)
        #expect(try pooled.windows().first?.percent == 10)
    }
    @Test func missingOrUnlimitedQuotaIsNotAFullBattery() throws {
        for json in [#"{}"#, #"{"config":{"monthlyLimit":{"val":0},"used":{}}}"#] {
            let quota = try decode(GrokQuotaResponse.self, json)
            #expect(throws: ErrorKind.quotaUnavailable) { try quota.windows() }
        }
        for json in [#"{"quotaSnapshots":{}}"#, #"{"quotaSnapshots":{"chat":{"isUnlimitedEntitlement":true,"remainingPercentage":100}}}"#] {
            let quota = try decode(CopilotQuotaResponse.self, json)
            #expect(throws: ErrorKind.quotaUnavailable) { try quota.windows() }
        }
        for json in [#"{}"#, #"{"isUnlimited":true,"individualUsage":{"plan":{"autoPercentUsed":0}}}"#, #"{"individualUsage":{"plan":{"enabled":false,"used":0,"limit":100}}}"#] {
            let quota = try decode(CursorQuotaResponse.self, json)
            #expect(throws: ErrorKind.quotaUnavailable) { try quota.windows() }
        }
    }
    @Test func geminiReadsQuotaBlockAndLatestRedraw() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let text = "Session tokens: 99% used\n\u{1b}[33m87% used (Limit resets in 2h 10m)\u{1b}[0m\nUsage limit: 100\nUsage limits span all sessions and reset daily."
        let window = try #require(GeminiQuotaParser.map(text, now: now).first)
        #expect(window.percent == 87)
        #expect(window.resetsAt == now.addingTimeInterval(7800))
        let exhausted = text + "\nLimit reached, resets in 1h\nUsage limit: 100\nUsage limits span all sessions and reset daily."
        #expect(try GeminiQuotaParser.map(exhausted).first?.percent == 100)
        #expect(throws: ErrorKind.quotaUnavailable) { try GeminiQuotaParser.map("Session tokens: 87% used") }
        #expect(throws: ErrorKind.quotaUnavailable) { try GeminiQuotaParser.map("Usage limit: 100\nSession tokens: 87% used") }
        let legacy = "gemini-2.5-pro 0 97.5% (Resets in 2h 10m)\ngemini-2.5-flash 0 100% (Resets in 2h 10m)"
        #expect(try GeminiQuotaParser.map(legacy).map(\.percent) == [2.5, 0])
    }
    @Test func oldSettingsAndNewProviderIsolation() throws {
        let old = #"{"interval":900,"showPercent":false,"notify80":true,"notify100":false,"perAccountMenu":true,"extraUsage":false,"language":"en","claudeBinary":"/fixture/claude","codexBinary":"/fixture/codex"}"#
        var settings = try decode(Settings.self, old)
        #expect(settings.interval == 900 && settings.language == "en")
        #expect(settings.binaryOverride(.codex) == "/fixture/codex")
        #expect(settings.binaryOverride(.copilot) == nil)
        settings.additionalBinaries = ["cursor": "/fixture/agent"]
        #expect(try JSONDecoder().decode(Settings.self, from: JSONEncoder().encode(settings)) == settings)
        for provider in [Provider.gemini, .grok, .copilot, .cursor] {
            let account = Account(provider: provider)
            #expect(account.environment.isEmpty)
            let command = LoginCommand.shell(account: account, binary: "/fixture/" + provider.binaryName)
            #expect(command.hasSuffix(provider == .gemini ? "'/fixture/gemini'" : " login"))
            #expect(!command.contains(" auth login"))
            #expect(throws: ErrorKind.invalidConfig) { try AppPaths().validate(Account(provider: provider, configDirMode: .custom, configDir: URL(fileURLWithPath: "/tmp/fixture")), among: []) }
            #expect(throws: ErrorKind.invalidConfig) { try AppPaths().validate(Account(provider: provider), among: [account]) }
        }
    }
}

@Suite struct AdditionalTransportTests {
    @Test func grokRPCReadsOnlyIdentityAndQuota() async throws {
        let usage = try await GrokProvider().fetch(account: Account(provider: .grok), binary: quotaFixture)
        #expect(usage.providerIdentity.accountId == "fixture-user")
        #expect(usage.providerIdentity.orgId == "fixture-org")
        #expect(usage.windows.first?.percent == 87)
    }
    @Test func copilotHandlesFragmentedContentLengthAndReverseRequests() async throws {
        let usage = try await CopilotProvider().fetch(account: Account(provider: .copilot), binary: quotaFixture)
        #expect(usage.providerIdentity.accountId == "github.com:fixture-user")
        #expect(usage.windows.first?.remainingPercent(at: Date()) == 13)
    }
    @Test func rpcUnsupportedAndTimeout() async throws {
        for mode in ["unsupported", "timeout"] {
            let rpc = try QuotaRPC(binary: quotaFixture, arguments: ["agent", "stdio"], environment: ["QUOTA_FIXTURE": mode], framing: .lines)
            defer { rpc.close() }
            do { _ = try await rpc.request("initialize", timeout: 2); Issue.record("Expected failure") }
            catch { #expect(error as? ErrorKind == (mode == "timeout" ? .timeout : .quotaUnavailable)) }
        }
    }
    @Test func geminiPTYOnlySendsStatsCommands() async throws {
        let usage = try await GeminiProvider().fetch(account: Account(provider: .gemini), binary: quotaFixture)
        #expect(usage.windows.first?.percent == 87)
        #expect(usage.identity?.email == "fixture@example.invalid")
    }
}

private func cursorCredential(expiry: Double = 4_000_000_000) throws -> CursorCredential {
    let payload = Data("{\"sub\":\"auth0|fixture-user\",\"email\":\"fixture@example.invalid\",\"exp\":\(expiry)}".utf8)
        .base64EncodedString().replacingOccurrences(of: "=", with: "").replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
    return try CursorCredential(data: Data("{\"accessToken\":\"header.\(payload).signature\"}".utf8))
}
private struct CursorFixtureCredentials: CursorCredentialReading {
    func read() throws -> CursorCredential { try cursorCredential() }
}
private actor CursorFixtureHTTP: HTTPClient {
    let status: Int
    var requests: [URLRequest] = []
    init(status: Int = 200) { self.status = status }
    func get(_ request: URLRequest) -> HTTPResult {
        requests.append(request)
        return .init(data: Data(#"{"membershipType":"pro","individualUsage":{"plan":{"used":87,"limit":100}}}"#.utf8), status: status, retryAfter: "900")
    }
}
@Suite struct CursorSessionTests {
    @Test func sessionIsUsedOnlyAtFixedEndpointAndNeverCached() async throws {
        let http = CursorFixtureHTTP()
        let usage = try await CursorProvider(credentials: CursorFixtureCredentials(), http: http).fetch(account: authorizedCursorAccount(), binary: "/unused")
        let request = try #require(await http.requests.first)
        #expect(request.url?.absoluteString == "https://cursor.com/api/usage-summary")
        #expect(request.value(forHTTPHeaderField: "Cookie")?.hasPrefix("WorkosCursorSessionToken=fixture-user%3A%3A") == true)
        #expect(usage.windows.first?.percent == 87)
        let cache = String(decoding: try JSONEncoder().encode(CachedAccountUsage(usage)), as: UTF8.self)
        #expect(!cache.contains("fixture-user") && !cache.contains("fixture@example.invalid") && !cache.contains("signature"))
    }
    @Test(arguments: [401, 403, 429]) func handlesAuthenticationAndBackoff(status: Int) async throws {
        do {
            _ = try await CursorProvider(credentials: CursorFixtureCredentials(), http: CursorFixtureHTTP(status: status)).fetch(account: authorizedCursorAccount(), binary: "/unused")
            Issue.record("Expected failure")
        } catch {
            let failure = try #require(error as? ProviderFailure)
            #expect(failure.kind == (status == 401 ? .tokenInvalid : status == 403 ? .policy : .rateLimited))
            #expect(failure.identity?.accountId == "fixture-user")
            if status == 429 { #expect(failure.retryAfter == 900) }
        }
    }
    @Test func malformedAndExpiredCredentialsRequireLogin() throws {
        #expect(throws: ErrorKind.needsLogin) { try cursorCredential(expiry: 1) }
        #expect(throws: ErrorKind.needsLogin) { try CursorCredential(data: Data(#"{"accessToken":"not-a-jwt"}"#.utf8)) }
    }
}

private func authorizedCursorAccount() -> Account {
    var account = Account(provider: .cursor); account.cursorWebUsageEnabled = true; return account
}
