import Foundation
import Testing
@testable import AIUsageCore

func fixture(_ name: String) throws -> Data { try Data(contentsOf: Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures")!) }
func windows(_ name: String) throws -> [UsageWindow] { ClaudeUsageMapper.map(try JSONDecoder().decode(ClaudeUsageResponse.self, from: fixture(name))) }

@Suite struct MapperTests {
    @Test func codexAllBucketsAndWindowDurations() throws {
        let mapped = CodexRateLimitsMapper.map(try JSONDecoder().decode(CodexRateLimits.self, from: fixture("codex_rateLimits")))
        #expect(mapped.count == 3); #expect(mapped[0].id == "codex:codex:primary")
        #expect(mapped[0].durationMinutes == 10080); #expect(mapped[0].label == L("Semaine"))
        #expect(mapped[1].group == "GPT-5.3-Codex-Spark"); #expect(mapped[0].resetsAt?.timeIntervalSince1970 == 1789805490)
        #expect(mapped.filter(\.isActive).count == 1)
    }
    @Test func codexFallbackAndGlobalBlock() throws {
        let data = Data(#"{"ordinaryUsageAllowed":false,"rateLimits":{"primary":{"usedPercent":30}},"rateLimitsByLimitId":{}}"#.utf8)
        let mapped = CodexRateLimitsMapper.map(try JSONDecoder().decode(CodexRateLimits.self, from: data))
        #expect(mapped.count == 1); #expect(mapped[0].severity == .blocked)
    }
    @Test func claudePrefersLimitsAndIgnoresUnknownKeys() throws {
        let mapped = try windows("claude_usage")
        #expect(mapped.count == 3); #expect(mapped[2].id == "claude:weekly_scoped:fable:")
        #expect(mapped[2].percent == 81); #expect(mapped[2].isActive)
        #expect(mapped[0].resetsAt != nil)
    }
    @Test func legacyAndExtras() throws {
        let mapped = try windows("claude_usage_minimal")
        #expect(mapped.count == 2); #expect(mapped[0].resetsAt != nil); #expect(mapped[1].resetsAt == nil)
        let response = try JSONDecoder().decode(ClaudeUsageResponse.self, from: fixture("claude_usage"))
        #expect(ClaudeUsageMapper.map(response, includeExtras: true).last?.id == "claude:extra_usage::")
    }
    @Test func blockedAndScopedIDs() throws {
        let data = Data(#"{"limits":[{"kind":"weekly_scoped","percent":50,"severity":"blocked","scope":{"model":{"display_name":"Fable"}}},{"kind":"weekly_scoped","percent":90,"scope":{"model":{"display_name":"Sonnet"}}}]}"#.utf8)
        let mapped = ClaudeUsageMapper.map(try JSONDecoder().decode(ClaudeUsageResponse.self, from: data))
        #expect(mapped[0].severity == .blocked); #expect(Set(mapped.map(\.id)).count == 2)
    }
    @Test func legacyScopedQuotasContributeToRemainingMinimum() throws {
        let data = Data(#"{"five_hour":{"utilization":10},"seven_day":{"utilization":20},"seven_day_sonnet":{"utilization":90,"resets_at":"2099-09-15T01:00:00Z"},"seven_day_opus":{"utilization":95},"seven_day_oauth_apps":{"utilization":40},"seven_day_cowork":{"utilization":50,"locked_reason":"blocked"}}"#.utf8)
        let mapped = ClaudeUsageMapper.map(try JSONDecoder().decode(ClaudeUsageResponse.self, from: data))
        let usage = AccountUsage(accountId: UUID(), windows: mapped, source: "test")
        #expect(mapped.map(\.id) == ["claude:session::", "claude:weekly_all::", "claude:weekly_scoped:cowork:", "claude:weekly_scoped:oauth-apps:", "claude:weekly_scoped:opus:", "claude:weekly_scoped:sonnet:"])
        #expect(usage.remainingPercent(at: Date()) == 5)
        #expect(mapped[5].displayLabel(language: "en") == "Week · Sonnet")
        #expect(mapped[5].resetsAt != nil)
        #expect(mapped[4].severity == .critical)
        #expect(mapped[2].severity == .blocked)
        #expect(mapped.dropFirst(2).allSatisfy { $0.durationMinutes == 10080 })
    }
    @Test func legacyScopedQuotasSkipMissingAndNullValues() throws {
        let data = Data(#"{"limits":[],"seven_day_sonnet":null,"seven_day_opus":{},"seven_day_cowork":{"utilization":0},"metadata":{"count":100},"future_flag":true}"#.utf8)
        let mapped = ClaudeUsageMapper.map(try JSONDecoder().decode(ClaudeUsageResponse.self, from: data))
        #expect(mapped.count == 1)
        #expect(mapped.first?.id == "claude:weekly_scoped:cowork:")
        #expect(mapped.first?.percent == 0)
    }
    @Test func currentLimitsOverrideLegacyScopedQuotas() throws {
        let data = Data(#"{"limits":[{"kind":"weekly_scoped","percent":20,"scope":{"model":{"display_name":"Sonnet"}}}],"seven_day_sonnet":{"utilization":90},"seven_day_opus":{"utilization":95}}"#.utf8)
        let mapped = ClaudeUsageMapper.map(try JSONDecoder().decode(ClaudeUsageResponse.self, from: data))
        #expect(mapped.count == 1)
        #expect(mapped.first?.id == "claude:weekly_scoped:sonnet:")
        #expect(mapped.first?.percent == 20)
    }
    @Test func unknownLegacyQuotasPreserveProviderNamesAndValues() throws {
        let data = Data(#"{"seven_day_new_model":{"display_name":"FutureModel v9","utilization":87,"resets_at":"2099-09-15T01:00:00Z"},"new_quota":{"display_name":"Provider allowance","utilization":12},"extra_usage":{"is_enabled":true,"utilization":100}}"#.utf8)
        let mapped = ClaudeUsageMapper.map(try JSONDecoder().decode(ClaudeUsageResponse.self, from: data))
        #expect(mapped.count == 2)
        #expect(mapped[0].id == "claude:legacy:new_quota")
        #expect(mapped[0].label == "Provider allowance")
        #expect(mapped[0].durationMinutes == nil)
        #expect(mapped[1].displayLabel(language: "en") == "Week · FutureModel v9")
        #expect(mapped[1].remainingPercent(at: Date()) == 13)
    }
    @Test func menuPercentageMarksResetsUntilConfirmed() {
        let now = Date()
        var usage = AccountUsage(accountId: UUID(), windows: [
            .init(id: "session", label: "Session", percent: 95, resetsAt: now.addingTimeInterval(-1))
        ], fetchedAt: now.addingTimeInterval(-3600), source: "test")
        #expect(usage.remainingPercentText(at: now) == "≈5%")
        usage.windows.append(.init(id: "week", label: "Week", percent: 60, resetsAt: now.addingTimeInterval(3600)))
        #expect(usage.remainingPercentText(at: now) == "≈5%")
        usage.windows[0].percent = 10
        #expect(usage.remainingPercentText(at: now) == "≈40%")
        usage.windows[0] = .init(id: "session", label: "Session", percent: 80, resetsAt: now.addingTimeInterval(300))
        #expect(usage.remainingPercentText(at: now) == "20%")
        #expect(!usage.hasUnconfirmedReset(at: now))
        usage.windows = []
        #expect(usage.remainingPercentText(at: now) == nil)
    }
    @Test func remainingQuotaIsIndependentOfRepresentativeAndResetDoesNotMutate() {
        let now = Date()
        let usage = AccountUsage(accountId: UUID(), windows: [
            .init(id: "active", label: "Active", percent: 60, resetsAt: now.addingTimeInterval(10), isActive: true),
            .init(id: "other", label: "Other", percent: 90, resetsAt: now.addingTimeInterval(100))], source: "test")
        #expect(usage.representative?.id == "active"); #expect(usage.remainingPercent(at: now) == 10)
        #expect(usage.windows[0].remainingPercent(at: now.addingTimeInterval(20)) == 40)
        #expect(usage.windows[0].percent == 60); #expect(usage.remainingPercent(at: now.addingTimeInterval(200)) == 10)
        #expect(UsageWindow(id: "fable", label: "Fable", percent: 87).remainingPercent(at: now) == 13)
        #expect(UsageWindow(id: "exceeded", label: "Extra", percent: 110).remainingPercent(at: now) == 0)
        #expect(UsageWindow(id: "empty", label: "Empty", percent: 0).remainingPercent(at: now) == 100)
    }
}
@Suite struct IdentityAndCacheTests {
    @Test func missingIDsAreNotIdentityChanges() {
        let known = ProviderIdentity(accountId: "123", email: "one@example.invalid")
        let partial = ProviderIdentity(email: "one@example.invalid")
        #expect(known.compare(to: partial) == .same)
        #expect(known.compare(to: .init()) == .incomparable)
        #expect(known.compare(to: .init(email: "two@example.invalid")) == .different)
        #expect(partial.merging(known).accountId == "123")
        #expect(known.hashed.compare(to: partial.hashed) == .same)
        #expect(ProviderIdentity(orgId: "a", email: "one").compare(to: .init(orgId: "b", email: "one")) == .different)
    }
    @Test func diskCacheContainsNoRawIdentity() throws {
        let usage = AccountUsage(accountId: UUID(), identity: .init(email: "secret@example.invalid", plan: "pro"), windows: [], source: "codex-rpc", providerIdentity: .init(accountId: "private-account-identity", orgId: "private-org-identity", email: "secret@example.invalid"))
        let data = try JSONEncoder().encode(CacheDocument(accounts: [.init(usage)]))
        let text = String(decoding: data, as: UTF8.self)
        #expect(!text.contains("secret@example")); #expect(!text.contains("private-account")); #expect(!text.contains("private-org"))
        let restored = try JSONDecoder().decode(CacheDocument.self, from: data)
        #expect(restored.accounts[0].restored.identity?.email == nil)
        #expect(restored.accounts[0].hashedIdentity.accountId?.count == 16)
    }
    @Test func serviceNamesAndEnvironment() {
        #expect(KeychainServiceName.name(configDir: "/tmp/claude-test") == "Claude Code-credentials-9adeedd0")
        #expect(KeychainServiceName.name(configDir: "/Users/jbd/Library/Application Support/AIUsage/accounts/claude-perso") == "Claude Code-credentials-f3b6a77e")
        #expect(KeychainServiceName.name(configDir: "ignored", secureStorageDir: "") == "Claude Code-credentials")
        #expect(Account(provider: .claude).environment.isEmpty)
        let account = Account(provider: .claude, configDirMode: .custom, configDir: URL(fileURLWithPath: "/tmp/claude-test"))
        #expect(account.environment["CLAUDE_SECURESTORAGE_CONFIG_DIR"] == nil)
        var dedicated = account; dedicated.configDirMode = .dedicated
        #expect(dedicated.environment["CLAUDE_SECURESTORAGE_CONFIG_DIR"] == dedicated.environment["CLAUDE_CONFIG_DIR"])
    }
    @Test func loginShellQuotingAndRedaction() {
        #expect(LoginCommand.quote("a'b $(touch /tmp/no)") == "'a'\\''b $(touch /tmp/no)'")
        #expect(Redaction.redact("mail x@example.com token sk-ant-oat01-secret") == "mail [redacted] token [redacted]")
    }
}
final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value = Date(timeIntervalSince1970: 1000)
    func now() -> Date { lock.withLock { value } }
    func advance(_ seconds: TimeInterval) { lock.withLock { value.addTimeInterval(seconds) } }
}
@Suite struct RateGateTests {
    @Test func allTriggersRespectMinimumAndSingleFlight() async {
        let clock = TestClock(), gate = RateGate(provider: .claude, now: { clock.now() }, jitter: { 0 })
        #expect(await gate.begin(.manual))
        clock.advance(500); #expect(await gate.begin(.manual) == false)
        await gate.finish(interval: 60)
        #expect(await gate.begin(.scheduled)); await gate.finish(interval: 60)
        clock.advance(60)
        for reason in [RefreshReason.manual, .popover, .wake, .account, .renewed] { #expect(await gate.begin(reason) == false) }
        clock.advance(60); #expect(await gate.begin(.scheduled))
    }
    @Test func retryCreditNeverBypasses429AndIsOneShot() async {
        let clock = TestClock(), gate = RateGate(provider: .claude, now: { clock.now() }, jitter: { 0 })
        #expect(await gate.begin(.manual))
        await gate.finish(error: .init(.rateLimited, retryAfter: 900), interval: 60)
        await gate.authorizeRenewedRetry(); clock.advance(899)
        #expect(await gate.begin(.renewed) == false); #expect(await gate.begin(.manual) == false)
        clock.advance(1); #expect(await gate.begin(.renewed)); await gate.finish(interval: 60)
        #expect(await gate.begin(.renewed) == false)
    }
    @Test func manualOnlyBypassesSoftBackoff() async {
        let clock = TestClock(), gate = RateGate(provider: .claude, now: { clock.now() }, jitter: { 0.5 })
        #expect(await gate.begin(.scheduled)); await gate.finish(error: .init(.network), interval: 300)
        clock.advance(120); #expect(await gate.begin(.scheduled) == false); #expect(await gate.begin(.manual))
        await gate.finish(error: .init(.policy), interval: 300); clock.advance(600)
        #expect(await gate.begin(.manual) == false)
    }
    @Test func backoffIsBounded() { #expect(Backoff.delay(interval: 300, failures: 100, jitter: 0.5) == 3600) }
}
@Suite struct NotificationTests {
    @Test func accountsAndThresholdsAreIndependent() {
        let now = Date(), reset = Date().addingTimeInterval(300)
        var memory = NotificationMemory()
        var usage = AccountUsage(accountId: UUID(), windows: [.init(id: "same", label: "Quota", percent: 81, resetsAt: reset)], source: "test")
        let first = memory.candidates(usage: usage, thresholds: [80, 100], now: now)
        #expect(first.count == 1); first.forEach { memory.mark($0) }
        #expect(memory.candidates(usage: usage, thresholds: [80, 100], now: now).isEmpty)
        usage.windows[0].percent = 100
        #expect(memory.candidates(usage: usage, thresholds: [80, 100], now: now).map(\.threshold) == [100])
        usage.accountId = UUID()
        #expect(memory.candidates(usage: usage, thresholds: [80, 100], now: now).count == 2)
    }
    @Test func expiredWindowsDoNotEmitOrRearm() {
        let now = Date(); var memory = NotificationMemory()
        let usage = AccountUsage(accountId: UUID(), windows: [.init(id: "q", label: "Q", percent: 100, resetsAt: now.addingTimeInterval(-1))], source: "test")
        #expect(memory.candidates(usage: usage, thresholds: [80, 100], now: now).isEmpty)
    }
}


@Suite struct DisplayLanguageTests {
    @Test(arguments: AppLanguage.allCases) func everySelectableLanguageHasPackagedTranslations(language: AppLanguage) throws {
        let code = language.rawValue
        let expected: [String: (String, String)] = [
            "fr": ("Semaine", "maj il y a 7 min"), "en": ("Week", "updated 7 min ago"),
            "it": ("Settimana", "aggiornato 7 min fa"), "es": ("Semana", "actualizado hace 7 min"),
            "de": ("Woche", "vor 7 Min. aktualisiert"), "pt-BR": ("Semana", "atualizado há 7 min")
        ]
        let (week, updated) = try #require(expected[code])
        let window = UsageWindow(id: "claude:weekly_scoped:fable:", label: "Semaine · Fable", percent: 87)
        #expect(window.displayLabel(language: code) == week + " · Fable")
        #expect(String(format: L("maj il y a %d min", language: code), locale: appLocale(code), 7) == updated)
        if language != .french {
            #expect(L("Quota restant", language: code) != "Quota restant")
            #expect(L("Réglages…", language: code) != "Réglages…")
        }
    }
    @Test func cachedLabelsFollowSelectedLanguageWithoutTranslatingNames() throws {
        let windows: [UsageWindow] = [
            .init(id: "claude:weekly_scoped:fable:", label: "Semaine · Fable", percent: 87, durationMinutes: 10080),
            .init(id: "codex:codex:primary", label: "Session 5 h", percent: 10, durationMinutes: 300),
            .init(id: "codex:spark:secondary", label: "Week", group: "GPT-5.3-Codex-Spark", percent: 0, durationMinutes: 10080)
        ]
        let restored = try JSONDecoder().decode([UsageWindow].self, from: JSONEncoder().encode(windows))
        #expect(restored.map { $0.displayLabel(language: "en") } == ["Week · Fable", "5 h session", "Week"])
        #expect(restored.map { $0.displayLabel(language: "fr") } == ["Semaine · Fable", "Session 5 h", "Semaine"])
        #expect(restored.last?.group == "GPT-5.3-Codex-Spark")
        #expect(Account(provider: .claude, label: "Playlounge").displayName == "Claude - Playlounge")
        #expect(UsageWindow(id: "future", label: "Provider name", percent: 0).displayLabel(language: "fr") == "Provider name")
    }
    @Test func resetWeekdayUsesAppLanguage() {
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let base = Date.FormatStyle().weekday(.wide)
        let en = date.formatted(base.locale(appLocale("en")))
        let fr = date.formatted(base.locale(appLocale("fr")))
        #expect(en != fr)
    }
}
