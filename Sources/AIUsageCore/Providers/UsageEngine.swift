import Foundation

public enum FetchOutcome: Sendable {
    case success(AccountUsage), failure(ProviderFailure), missing, skipped(TimeInterval)
}
public actor UsageEngine {
    private let codex: any UsageProvider
    private let claude: ClaudeProvider
    private let grok: any UsageProvider = GrokProvider()
    private let copilot: any UsageProvider = CopilotProvider()
    private let gemini: any UsageProvider = GeminiProvider()
    private let cursor: any UsageProvider = CursorProvider()
    private let locator: BinaryLocator
    private let renewer: any CredentialRenewing
    private var gates: [UUID: RateGate] = [:]
    private var renewalTasks: [UUID: (id: UUID, task: Task<RenewalResult, Never>)] = [:]
    private var stopping = false
    public init(codex: any UsageProvider = CodexProvider(), claude: ClaudeProvider = ClaudeProvider(), locator: BinaryLocator = BinaryLocator(), renewer: any CredentialRenewing = ClaudeDelegatedRefresh()) {
        self.codex = codex; self.claude = claude; self.locator = locator; self.renewer = renewer
    }
    private func gate(_ account: Account) -> RateGate {
        if let gate = gates[account.id] { return gate }
        let gate = RateGate(provider: account.provider); gates[account.id] = gate; return gate
    }
    public func refresh(account: Account, settings: Settings, reason: RefreshReason) async -> FetchOutcome {
        if account.provider == .cursor && account.cursorWebUsageEnabled != true { return .failure(.init(.permissionRequired)) }
        let gate = gate(account)
        guard await gate.begin(reason) else { return .skipped(await gate.remaining()) }
        guard let binary = await locator.locate(account.provider, override: settings.binaryOverride(account.provider)) else {
            await gate.finish(interval: settings.interval); return .missing
        }
        do {
            let provider: any UsageProvider = switch account.provider {
            case .claude: claude; case .codex: codex; case .gemini: gemini; case .grok: grok; case .copilot: copilot; case .cursor: cursor
            }
            let usage = try await withThrowingTaskGroup(of: AccountUsage.self) { group in
                group.addTask { try await provider.fetch(account: account, binary: binary, includeExtras: settings.extraUsage, forceIdentity: reason == .account) }
                group.addTask { try await Task.sleep(for: .seconds(45)); throw ErrorKind.timeout }
                defer { group.cancelAll() }
                return try await group.next()!
            }
            await gate.finish(interval: settings.interval); Log.refresh(account: account, windows: usage.windows.count)
            return .success(usage)
        } catch {
            let failure = error as? ProviderFailure ?? ProviderFailure(error as? ErrorKind ?? (Task.isCancelled ? .cancelled : .process))
            await gate.finish(error: failure, interval: settings.interval); Log.refresh(account: account, error: failure.kind)
            return .failure(failure)
        }
    }
    public func renew(account: Account, settings: Settings) async -> RenewalResult {
        guard !stopping, !Task.isCancelled, account.provider == .claude else { return .deferred }
        if let job = renewalTasks[account.id] { return await job.task.value }
        guard let binary = await locator.locate(.claude, override: settings.binaryOverride(.claude)),
              let (start, rejected) = try? await claude.renewalContext(account: account),
              !stopping, !Task.isCancelled else { return .deferred }
        if let job = renewalTasks[account.id] { return await job.task.value }
        let id = UUID()
        let task = Task<RenewalResult, Never> {
            let result = await renewer.renew(account: account, binary: binary, startingHash: start, rejectedHash: rejected)
            guard !Task.isCancelled else { return .deferred }
            guard result == .succeeded else { return result }
            // Both an expired credential and a rejected request leave usage unread.
            await gate(account).authorizeRenewedRetry()
            return .succeeded
        }
        renewalTasks[account.id] = (id, task)
        let success = await task.value
        if renewalTasks[account.id]?.id == id { renewalTasks[account.id] = nil }
        return success
    }
    public func cancel(_ id: UUID) { renewalTasks[id]?.task.cancel() }
    public func stop() async {
        stopping = true
        let tasks = renewalTasks.values.map(\.task)
        for task in tasks { task.cancel() }
        for task in tasks { _ = await task.value }
        renewalTasks.removeAll()
    }
}
