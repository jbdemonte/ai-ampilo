import Foundation

public struct AppPaths: Sendable {
    public let root: URL
    public init(root: URL? = nil) {
        self.root = root ?? ProcessInfo.processInfo.environment["AIUSAGE_DATA_DIR"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/AIUsage")
    }
    public func file(_ name: String) -> URL { root.appendingPathComponent(name) }
    public func prepare() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }
    public func write<T: Encodable>(_ value: T, to name: String) throws {
        try prepare()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(value).write(to: file(name), options: [.atomic, .completeFileProtectionUnlessOpen])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file(name).path)
    }
    public func read<T: Decodable>(_ type: T.Type, from name: String) throws -> T? {
        guard FileManager.default.fileExists(atPath: file(name).path) else { return nil }
        return try JSONDecoder().decode(type, from: Data(contentsOf: file(name)))
    }
    public func validate(_ account: Account, among accounts: [Account]) throws {
        guard account.provider.supportsConfigDirectory || account.configDirMode == .cliDefault else { throw ErrorKind.invalidConfig }
        guard account.configDirMode == .cliDefault || account.configDir?.path.hasPrefix("/") == true else { throw ErrorKind.invalidConfig }
        let target = account.resolvedConfigDir.resolvingSymlinksInPath().standardizedFileURL
        guard !accounts.contains(where: { $0.id != account.id && $0.provider == account.provider && $0.resolvedConfigDir.resolvingSymlinksInPath().standardizedFileURL == target }) else { throw ErrorKind.invalidConfig }
    }
}

public struct CachedAccountUsage: Codable, Sendable {
    public var accountId: UUID
    public var windows: [UsageWindow]
    public var fetchedAt: Date
    public var source: String
    public var plan: String?
    public var tier: String?
    public var hashedIdentity: ProviderIdentity
    public init(_ usage: AccountUsage, knownIdentity: ProviderIdentity? = nil) {
        accountId = usage.accountId; windows = usage.windows; fetchedAt = usage.fetchedAt; source = usage.source
        plan = usage.identity?.plan; tier = usage.identity?.tier
        hashedIdentity = knownIdentity ?? usage.providerIdentity.hashed
    }
    public var restored: AccountUsage {
        .init(accountId: accountId, identity: .init(plan: plan, tier: tier), windows: windows, fetchedAt: fetchedAt, source: source)
    }
}
public struct CacheDocument: Codable, Sendable {
    public var version = 1
    public var accounts: [CachedAccountUsage] = []
    public var notifications = NotificationMemory()
    public init(accounts: [CachedAccountUsage] = [], notifications: NotificationMemory = .init()) { self.accounts = accounts; self.notifications = notifications }
}

public struct NotificationKey: Codable, Hashable, Sendable {
    public var accountId: UUID
    public var windowId: String
    public var cycle: Int64
    public var threshold: Int
}
public struct NotificationMemory: Codable, Sendable {
    public var sent: Set<NotificationKey> = []
    public var reconnect: [UUID: Date] = [:]
    public init() {}
    public mutating func purge(_ id: UUID) { sent = sent.filter { $0.accountId != id }; reconnect[id] = nil }
    public mutating func candidates(usage: AccountUsage, thresholds: [Int], now: Date) -> [NotificationKey] {
        var result: [NotificationKey] = []
        for window in usage.windows {
            // Local decay is a presentation only estimate: never rearm or emit notifications from it.
            guard !window.unconfirmedReset(at: now) else { continue }
            for threshold in thresholds {
                let prior = sent.first { $0.accountId == usage.accountId && $0.windowId == window.id && $0.threshold == threshold }
                let cycle = window.resetsAt.map { Int64($0.timeIntervalSince1970) } ?? prior?.cycle ?? Int64(now.timeIntervalSince1970 / 86400)
                sent = sent.filter { key in
                    !(key.accountId == usage.accountId && key.windowId == window.id && key.threshold == threshold &&
                      (key.cycle != cycle || window.percent < Double(threshold - 10)))
                }
                let key = NotificationKey(accountId: usage.accountId, windowId: window.id, cycle: cycle, threshold: threshold)
                if window.percent >= Double(threshold), !sent.contains(key) { result.append(key) }
            }
        }
        return result
    }
    public mutating func mark(_ key: NotificationKey) { sent.insert(key) }
}

public struct DiagnosticReport: Encodable, Sendable {
    public struct Entry: Encodable, Sendable {
        public var id: UUID
        public var provider: Provider
        public var emailHash: String?
        public var state: String
        public var fetchedAt: Date?
        public init(account: Account, state: AccountState?) {
            id = account.id; provider = account.provider; self.state = state?.category ?? "unread"
            emailHash = state?.usage?.identity?.email.map { digest($0, length: 6) }; fetchedAt = state?.usage?.fetchedAt
        }
    }
    public var appVersion = "1.0.0"
    public var generatedAt = Date()
    public var osVersion = ProcessInfo.processInfo.operatingSystemVersionString
    public var binaryPaths: [String: String]
    public var cliVersions: [String: String]
    public var accounts: [Entry]
    public init(binaryPaths: [String: String], cliVersions: [String: String], accounts: [Entry]) {
        self.binaryPaths = binaryPaths.mapValues(Redaction.redact); self.cliVersions = cliVersions; self.accounts = accounts
    }
}
