import Foundation
import Observation
import AppKit
import Network
import UserNotifications
import AIUsageCore

@MainActor @Observable final class UsageStore {
    var accounts: [Account] = []
    var states: [UUID: AccountState] = [:]
    var lastRefresh: Date?
    var now = Date()
    var settings = Settings() { didSet { if ready { settingsChanged() } } }
    var storageError: String?
    var online = true
    var binaryPaths: [Provider: String] = [:]
    var versions: [Provider: String] = [:]
    var deferred: [UUID: Date] = [:]
    var identityChanged: [UUID: Date] = [:]
    var connecting: Set<UUID> = []
    var active: [UUID: Task<FetchOutcome, Never>] = [:]
    private var renewals: [UUID: Task<Void, Never>] = [:]
    let paths: AppPaths
    @ObservationIgnored private let engine = UsageEngine()
    @ObservationIgnored private let scheduler = RefreshScheduler()
    @ObservationIgnored private var knownIdentities: [UUID: ProviderIdentity] = [:] // hashes only
    @ObservationIgnored private var memory = NotificationMemory()
    @ObservationIgnored private var ready = false
    @ObservationIgnored private var monitor: NWPathMonitor?
    @ObservationIgnored private var wakeObserver: NSObjectProtocol?
    @ObservationIgnored private var clockTask: Task<Void, Never>?
    @ObservationIgnored private var wakeTask: Task<Void, Never>?
    @ObservationIgnored private var notificationBusy = false
    @ObservationIgnored private var stopping = false
    @ObservationIgnored private var statuslineSource: DispatchSourceFileSystemObject?
    @ObservationIgnored private var statuslineDates: [UUID: Date] = [:]

    init(paths: AppPaths = .init()) {
        self.paths = paths
        do {
            accounts = try paths.read([Account].self, from: "accounts.json") ?? []
            settings = try paths.read(Settings.self, from: "settings.json") ?? .init()
            for account in accounts { try paths.validate(account, among: accounts) }
            let cache = try paths.read(CacheDocument.self, from: "cache.json") ?? .init()
            memory = cache.notifications
            for item in cache.accounts where accounts.contains(where: { $0.id == item.accountId }) {
                states[item.accountId] = .stale(item.restored, reason: L("Identité non vérifiée"))
                knownIdentities[item.accountId] = item.hashedIdentity
            }
        } catch { storageError = ErrorKind.storage.message }
        applyLanguage()
        ready = true
    }
    var enabledAccounts: [Account] { accounts.filter(\.enabled) }
    var isRefreshing: Bool { !active.isEmpty }
    var allFailed: Bool { !enabledAccounts.isEmpty && enabledAccounts.allSatisfy { states[$0.id] != nil && states[$0.id]?.isOK == false } }

    func start() async {
        if isDemo { loadDemo(); return }
        await detectBinaries()
        if accounts.isEmpty && storageError == nil && !FileManager.default.fileExists(atPath: paths.file("accounts.json").path) {
            accounts = Provider.allCases.filter { $0.automaticallyAdded && binaryPaths[$0] != nil }.map { Account(provider: $0, label: L("Perso")) }
            saveAccounts()
        }
        let monitor = NWPathMonitor(); self.monitor = monitor
        monitor.pathUpdateHandler = { [weak self] path in
            let satisfied = path.status == .satisfied
            Task { @MainActor [weak self] in
                guard let self else { return }; let wasOnline = self.online; self.online = satisfied
                if satisfied && !wasOnline { await self.refresh(.network) }
            }
        }
        monitor.start(queue: DispatchQueue(label: "com.jbd.AIUsage.network"))
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.wakeTask?.cancel()
                self.wakeTask = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(10)) } catch { return }
                    await self?.refresh(.wake)
                }
            }
        }
        clockTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(30)) } catch { return }
                self?.now = Date()
            }
        }
        await schedule()
        watchStatuslines()
        await refresh(.scheduled)
    }
    func detectBinaries() async {
        for provider in Provider.allCases {
            let path = await BinaryLocator().locate(provider, override: settings.binaryOverride(provider))
            binaryPaths[provider] = path
            if let path, let result = try? await ProcessRunner().run(path, arguments: ["--version"], timeout: 5) {
                let version = String(decoding: result.stdout, as: UTF8.self).components(separatedBy: .whitespacesAndNewlines).first { $0.range(of: #"^\d+\.\d+\.\d+$"#, options: .regularExpression) != nil }
                versions[provider] = version ?? "—"
            }
        }
    }
    private func settingsChanged() {
        applyLanguage()
        do { try paths.write(settings, to: "settings.json") } catch { storageError = ErrorKind.storage.message }
        Task { await schedule() }
    }
    private var isDemo: Bool {
        ["--demo", "--render-demo", "--render-context"].contains(where: ProcessInfo.processInfo.arguments.contains)
    }
    private func applyLanguage() {
        if isDemo {
            var arguments = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
            arguments["AIUsageLanguage"] = settings.language
            UserDefaults.standard.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
        } else {
            UserDefaults.standard.set(settings.language, forKey: "AIUsageLanguage")
        }
    }
    private func schedule() async {
        await scheduler.start(interval: settings.interval) { [weak self] in await self?.refresh(.scheduled) }
    }
    func refresh(_ reason: RefreshReason, only id: UUID? = nil) async {
        guard !stopping, online || reason == .manual || reason == .account else { return }
        let targets = enabledAccounts.filter { id == nil || $0.id == id }
        await withTaskGroup(of: Void.self) { group in
            for account in targets { group.addTask { await self.refreshOne(account, reason: reason) } }
        }
    }
    private func refreshOne(_ account: Account, reason: RefreshReason) async {
        guard active[account.id] == nil, renewals[account.id] == nil, !stopping else { return }
        let settings = settings
        let task = Task { await engine.refresh(account: account, settings: settings, reason: reason) }
        active[account.id] = task
        let result = await task.value
        active[account.id] = nil
        guard !task.isCancelled, !stopping, accounts.contains(where: { $0 == account && $0.enabled }) else { return }
        switch result {
        case .skipped(let delay): deferred[account.id] = Date().addingTimeInterval(delay); return
        case .missing: states[account.id] = .cliMissing(account.provider)
        case .success(let usage):
            applyIdentity(usage.providerIdentity, for: account.id)
            states[account.id] = .ok(usage); connecting.remove(account.id); deferred[account.id] = nil
            await notify(usage, account: account)
        case .failure(let error):
            if let identity = error.identity { applyIdentity(identity, for: account.id) }
            let last = states[account.id]?.usage
            switch error.kind {
            case .needsLogin:
                states[account.id] = .needsLogin; knownIdentities[account.id] = nil; memory.purge(account.id)
            case .permissionRequired: states[account.id] = .permissionRequired
            case .tokenInvalid:
                if account.provider == .claude && reason != .renewed {
                    if reason == .popover { states[account.id] = .renewalPending(last) }
                    else { beginRenewal(account, last: last, settings: settings) }
                } else {
                    states[account.id] = .tokenInvalid(last)
                    await notifyReconnect(account)
                }
            case .network, .timeout, .server, .rateLimited:
                states[account.id] = last.map { .stale($0, reason: error.kind.message) } ?? .error(error.kind.message, nil)
            default: states[account.id] = .error(error.kind.message, last)
            }
        }
        now = Date(); lastRefresh = now; saveCache()
    }
    private func beginRenewal(_ account: Account, last: AccountUsage?, settings: Settings) {
        states[account.id] = .renewing(last)
        renewals[account.id] = Task { [weak self] in
            guard let self else { return }
            let result = await engine.renew(account: account, settings: settings)
            renewals[account.id] = nil
            guard !Task.isCancelled, !stopping, accounts.contains(where: { $0.id == account.id && $0.enabled }) else { return }
            switch result {
            case .succeeded: await refresh(.renewed, only: account.id)
            case .deferred: states[account.id] = .renewalPending(states[account.id]?.usage)
            case .failed:
                states[account.id] = .tokenInvalid(states[account.id]?.usage)
                await notifyReconnect(account)
                saveCache()
            }
        }
    }
    private func applyIdentity(_ identity: ProviderIdentity, for id: UUID) {
        let incoming = identity.hashed
        guard incoming != ProviderIdentity() else { return }
        if let old = knownIdentities[id] {
            switch old.compare(to: incoming) {
            case .different:
                states[id] = nil; memory.purge(id); identityChanged[id] = Date(); knownIdentities[id] = incoming
                statuslineDates[id] = Date()
                if let account = accounts.first(where: { $0.id == id }) {
                    try? FileManager.default.removeItem(at: StatuslineInstallation(paths: paths).outputURL(account: account))
                }
            case .same: knownIdentities[id] = old.merging(incoming)
            case .incomparable: break
            }
        } else { knownIdentities[id] = incoming }
    }
    func add(_ account: Account) throws {
        try paths.validate(account, among: accounts)
        if account.configDirMode == .dedicated { try FileManager.default.createDirectory(at: account.resolvedConfigDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) }
        accounts.append(account); saveAccounts()
        Task { await refresh(.account, only: account.id) }
    }
    func update(_ account: Account) {
        guard let index = accounts.firstIndex(where: { $0.id == account.id }) else { return }
        accounts[index] = account; saveAccounts()
        if account.provider == .cursor && account.cursorWebUsageEnabled != true {
            active[account.id]?.cancel(); states[account.id] = .permissionRequired; saveCache(); return
        }
        if !account.enabled { active[account.id]?.cancel(); renewals[account.id]?.cancel(); Task { await engine.cancel(account.id) } }
        else { Task { await refresh(.account, only: account.id) } }
    }
    func rename(_ id: UUID, to label: String) -> Bool {
        let name = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, let index = accounts.firstIndex(where: { $0.id == id }) else { return false }
        var updated = accounts
        updated[index].label = name
        do {
            try paths.write(updated, to: "accounts.json")
            accounts = updated
            return true
        } catch { storageError = ErrorKind.storage.message; return false }
    }
    func remove(_ id: UUID) {
        if let account = accounts.first(where: { $0.id == id }), account.statuslineEnabled == true {
            do { try StatuslineInstallation(paths: paths).uninstall(account: account) } catch { storageError = ErrorKind.storage.message; return }
        }
        active[id]?.cancel(); renewals[id]?.cancel(); Task { await engine.cancel(id) }
        accounts.removeAll { $0.id == id }; states[id] = nil; knownIdentities[id] = nil; memory.purge(id)
        saveAccounts(); saveCache()
        // Removing a row never logs out or deletes a user's CLI directory.
    }
    func saveAccounts() { do { try paths.write(accounts, to: "accounts.json") } catch { storageError = ErrorKind.storage.message } }
    func saveCache() {
        let cached = accounts.compactMap { account in states[account.id]?.usage.map { CachedAccountUsage($0, knownIdentity: knownIdentities[account.id]) } }
        do { try paths.write(CacheDocument(accounts: cached, notifications: memory), to: "cache.json") } catch { storageError = ErrorKind.storage.message }
    }
    func clearCache() {
        states.removeAll(); knownIdentities.removeAll(); memory = .init(); saveCache()
        Task { await refresh(.manual) }
    }
    func login(_ account: Account) async {
        guard let binary = await BinaryLocator().locate(account.provider, override: settings.binaryOverride(account.provider)) else { states[account.id] = .cliMissing(account.provider); return }
        do {
            if account.configDirMode != .cliDefault { try FileManager.default.createDirectory(at: account.resolvedConfigDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) }
            let result = try await ProcessRunner().run("/usr/bin/osascript", arguments: ["-e", LoginCommand.appleScript(account: account, binary: binary)], timeout: 15)
            guard result.exitCode == 0 else { throw ErrorKind.process }
            connecting.insert(account.id)
        } catch { states[account.id] = .error(L("Impossible d’ouvrir Terminal. Copiez la commande depuis les réglages."), states[account.id]?.usage) }
    }
    func exportDiagnostic() {
        let panel = NSSavePanel(); panel.nameFieldStringValue = "AIUsage-diagnostic.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let report = DiagnosticReport(binaryPaths: Dictionary(uniqueKeysWithValues: binaryPaths.map { ($0.key.rawValue, $0.value) }),
                                      cliVersions: Dictionary(uniqueKeysWithValues: versions.map { ($0.key.rawValue, $0.value) }),
                                      accounts: accounts.map { .init(account: $0, state: states[$0.id]) })
        do { let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; try encoder.encode(report).write(to: url, options: .atomic) }
        catch { storageError = ErrorKind.storage.message }
    }
    private func notify(_ usage: AccountUsage, account: Account) async {
        let thresholds: [Int] = (settings.notify80 ? [80] : []) + (settings.notify100 ? [100] : [])
        guard !thresholds.isEmpty, !notificationBusy else { return }
        let keys = memory.candidates(usage: usage, thresholds: thresholds, now: Date())
        guard !keys.isEmpty else { return }
        notificationBusy = true; defer { notificationBusy = false }
        let center = UNUserNotificationCenter.current()
        guard (try? await center.requestAuthorization(options: [.alert, .sound])) == true else { return }
        for key in keys {
            let content = UNMutableNotificationContent(); content.title = Redaction.redact(account.displayName)
            content.body = (usage.windows.first { $0.id == key.windowId }?.displayLabel() ?? L("Quota")) + " — \(100 - key.threshold) % " + L("restants")
            do {
                try await center.add(UNNotificationRequest(identifier: "\(key.accountId):\(key.windowId):\(key.cycle):\(key.threshold)", content: content, trigger: nil))
                memory.mark(key)
            } catch {}
        }
    }
    private func notifyReconnect(_ account: Account) async {
        guard settings.notify80 || settings.notify100, Date().timeIntervalSince(memory.reconnect[account.id] ?? .distantPast) >= 86400 else { return }
        let center = UNUserNotificationCenter.current()
        // Reconnection messages do not trigger the first permission prompt: only a crossed quota threshold does.
        guard await center.notificationSettings().authorizationStatus == .authorized else { return }
        guard !Task.isCancelled, !stopping, accounts.contains(where: { $0.id == account.id && $0.enabled }) else { return }
        let content = UNMutableNotificationContent(); content.title = L("Reconnexion requise"); content.body = Redaction.redact(account.displayName)
        do { try await center.add(.init(identifier: "reconnect:\(account.id)", content: content, trigger: nil)); memory.reconnect[account.id] = Date() } catch {}
    }
    func stop() async {
        stopping = true; clockTask?.cancel(); wakeTask?.cancel(); monitor?.cancel(); statuslineSource?.cancel()
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
        let reads = Array(active.values), jobs = Array(renewals.values)
        for task in reads { task.cancel() }
        for task in jobs { task.cancel() }
        await scheduler.stop(); await engine.stop()
        for task in reads { _ = await task.value }
        for task in jobs { await task.value }
        saveCache()
        await ProcessCleanup.wait()
    }
    private func loadDemo() {
        accounts = [Account(provider: .claude, label: "Studio"), Account(provider: .codex, label: "Personal")]
        let reset = Date().addingTimeInterval(15000)
        states[accounts[0].id] = .ok(.init(accountId: accounts[0].id, identity: .init(email: "studio@example.com", plan: "max", tier: "default_claude_max_20x"), windows: [
            .init(id: "claude:session::", label: L("Session 5 h"), percent: 11, resetsAt: reset, durationMinutes: 300),
            .init(id: "claude:weekly_all::", label: L("Semaine"), percent: 54, resetsAt: Date().addingTimeInterval(86400), durationMinutes: 10080),
            .init(id: "claude:weekly_scoped:fable:", label: "Semaine · Fable", percent: 87, resetsAt: reset, durationMinutes: 10080, isActive: true)], source: "demo"))
        states[accounts[1].id] = .ok(.init(accountId: accounts[1].id, identity: .init(email: "alex@example.com", plan: "pro"), windows: [
            .init(id: "codex:codex:primary", label: L("Semaine"), percent: 16, resetsAt: reset, durationMinutes: 10080, isActive: true),
            .init(id: "codex:spark:primary", label: L("Session 5 h"), group: "GPT-5.3-Codex-Spark", percent: 0, resetsAt: reset, durationMinutes: 300),
            .init(id: "codex:spark:secondary", label: L("Semaine"), group: "GPT-5.3-Codex-Spark", percent: 0, resetsAt: reset, durationMinutes: 10080)], source: "demo"))
        lastRefresh = Date()
    }
    func toggleStatusline(_ account: Account, enabled: Bool) {
        do {
            let installation = StatuslineInstallation(paths: paths)
            if enabled {
                guard let helper = Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("aiusage-cli") else { throw ErrorKind.process }
                try installation.install(account: account, helper: helper)
            } else { try installation.uninstall(account: account) }
            var updated = account; updated.statuslineEnabled = enabled; update(updated)
            watchStatuslines()
        } catch { storageError = L("Impossible de modifier la statusline. Vérifiez le dossier et la sauvegarde existante.") }
    }
    private func watchStatuslines() {
        statuslineSource?.cancel(); statuslineSource = nil
        guard accounts.contains(where: { $0.statuslineEnabled == true }) else { return }
        let directory = paths.file("statusline")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let fd = open(directory.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: .write, queue: .main)
        source.setEventHandler { [weak self] in Task { @MainActor [weak self] in self?.readStatuslines() } }
        source.setCancelHandler { close(fd) }; source.resume(); statuslineSource = source
    }
    private func readStatuslines() {
        for account in enabledAccounts where account.statuslineEnabled == true {
            let url = StatuslineInstallation(paths: paths).outputURL(account: account)
            guard let data = try? Data(contentsOf: url), let snapshot = try? JSONDecoder().decode(StatuslineSnapshot.self, from: data),
                  snapshot.fetchedAt > (statuslineDates[account.id] ?? .distantPast),
                  let usage = states[account.id]?.usage else { continue }
            statuslineDates[account.id] = snapshot.fetchedAt
            let merged = snapshot.merging(into: usage)
            if case .ok = states[account.id] { states[account.id] = .ok(merged) }
            else { states[account.id] = .stale(merged, reason: L("Données locales de Claude Code")) }
        }
        saveCache()
    }
}
