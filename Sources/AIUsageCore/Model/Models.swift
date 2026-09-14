import Foundation
import CryptoKit

public func L(_ key: String, language: String? = nil) -> String {
    let language = language ?? UserDefaults.standard.string(forKey: "AIUsageLanguage") ?? "fr"
    let resources = (Bundle.main.resourceURL?.appendingPathComponent("AIUsage_AIUsageCore.bundle").path)
        .flatMap { Bundle(path: $0) } ?? Bundle.module
    // SwiftPM lowercases regional resource directories (e.g. pt-BR → pt-br).
    let localizedPath = resources.path(forResource: language, ofType: "lproj")
        ?? resources.path(forResource: language.lowercased(), ofType: "lproj")
    let bundle = localizedPath.flatMap(Bundle.init(path:)) ?? resources
    return bundle.localizedString(forKey: key, value: key, table: nil)
}

public func appLocale(_ language: String? = nil) -> Locale {
    Locale(identifier: language ?? UserDefaults.standard.string(forKey: "AIUsageLanguage") ?? "fr")
}

public func digest(_ value: String, length: Int = 64) -> String {
    String(SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined().prefix(length))
}

public enum Provider: String, Codable, CaseIterable, Sendable {
    case claude, codex, gemini, grok, copilot, cursor
    public var title: String {
        switch self { case .claude: "Claude"; case .codex: "Codex"; case .gemini: "Gemini"; case .grok: "Grok"; case .copilot: "Copilot"; case .cursor: "Cursor" }
    }
    public var symbol: String {
        switch self { case .claude: "sun.max"; case .codex: "terminal"; case .gemini: "sparkles"; case .grok: "bolt"; case .copilot: "airplane"; case .cursor: "cursorarrow" }
    }
    public var binaryName: String { self == .cursor ? "cursor-agent" : rawValue }
    public var automaticallyAdded: Bool { self == .claude || self == .codex }
    public var experimental: Bool { self != .claude && self != .codex }
    public var supportsConfigDirectory: Bool { !experimental }
    public var minimumInterval: TimeInterval { self == .codex ? 60 : 120 }
    public var installURL: URL {
        let url: String = switch self {
        case .claude: "https://code.claude.com/docs/en/setup"
        case .codex: "https://developers.openai.com/codex/cli"
        case .gemini: "https://geminicli.com/docs/get-started/installation/"
        case .grok: "https://docs.x.ai/build/overview"
        case .copilot: "https://docs.github.com/en/copilot/how-tos/copilot-cli/set-up-copilot-cli/install-copilot-cli"
        case .cursor: "https://cursor.com/docs/cli/overview"
        }
        return URL(string: url)!
    }
}
public enum ConfigDirMode: String, Codable, CaseIterable, Sendable { case cliDefault, dedicated, custom }
public struct Account: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var provider: Provider
    public var label: String
    public var configDirMode: ConfigDirMode
    public var configDir: URL?
    public var enabled: Bool
    public var createdAt: Date
    public var keychainServiceOverride: String?
    public var statuslineEnabled: Bool?
    public var cursorWebUsageEnabled: Bool?
    public init(id: UUID = UUID(), provider: Provider, label: String = "", configDirMode: ConfigDirMode = .cliDefault,
                configDir: URL? = nil, enabled: Bool = true) {
        self.id = id; self.provider = provider; self.label = label.isEmpty ? provider.title : label
        self.configDirMode = configDirMode; self.configDir = configDir; self.enabled = enabled; createdAt = Date()
    }
    public var displayName: String {
        let name = label.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty || name.caseInsensitiveCompare(provider.title) == .orderedSame { return provider.title }
        if [" - ", " — ", " · "].contains(where: { name.lowercased().hasPrefix(provider.title.lowercased() + $0) }) { return name }
        return provider.title + " - " + name
    }
    public var resolvedConfigDir: URL {
        configDirMode == .cliDefault ? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".\(provider.rawValue)") : configDir!
    }
    public var configPath: String { resolvedConfigDir.path.precomposedStringWithCanonicalMapping }
    public var environment: [String: String] {
        guard configDirMode != .cliDefault else { return [:] }
        switch provider {
        case .claude:
            var env = ["CLAUDE_CONFIG_DIR": configPath]
            if configDirMode == .dedicated { env["CLAUDE_SECURESTORAGE_CONFIG_DIR"] = configPath }
            return env
        case .codex: return ["CODEX_HOME": configPath]
        default: return [:]
        }
    }
    public var keychainService: String {
        keychainServiceOverride ?? KeychainServiceName.name(configDir: configDirMode == .cliDefault ? nil : configPath)
    }
}
public enum Severity: String, Codable, Sendable {
    case normal, warning, critical, blocked
    public static func threshold(_ percent: Double) -> Self {
        percent >= 100 ? .blocked : percent >= 95 ? .critical : percent >= 80 ? .warning : .normal
    }
}
public struct UsageWindow: Identifiable, Codable, Hashable, Sendable {
    public var id: String
    public var label: String
    public var group: String?
    public var percent: Double // Consumed quota as returned by the provider; presentation uses remainingPercent.
    public var resetsAt: Date?
    public var durationMinutes: Int?
    public var severity: Severity
    public var isActive: Bool
    public init(id: String, label: String, group: String? = nil, percent: Double, resetsAt: Date? = nil,
                durationMinutes: Int? = nil, severity: Severity? = nil, isActive: Bool = false) {
        self.id = id; self.label = label; self.group = group; self.percent = percent.isFinite ? percent : 0
        self.resetsAt = resetsAt; self.durationMinutes = durationMinutes
        self.severity = severity ?? .threshold(percent); self.isActive = isActive
    }
    public func unconfirmedReset(at now: Date) -> Bool { resetsAt.map { $0 <= now } ?? false }
    public func remainingPercent(at now: Date) -> Double { 100 - min(100, max(0, percent)) }
}
public struct AccountIdentity: Codable, Hashable, Sendable {
    public var email: String?
    public var plan: String?
    public var tier: String?
    public init(email: String? = nil, plan: String? = nil, tier: String? = nil) { self.email = email; self.plan = plan; self.tier = tier }
}
public enum IdentityComparison: Sendable { case same, different, incomparable }
public struct ProviderIdentity: Codable, Hashable, Sendable {
    public var accountId: String?
    public var orgId: String?
    public var email: String?
    public init(accountId: String? = nil, orgId: String? = nil, email: String? = nil) { self.accountId = accountId; self.orgId = orgId; self.email = email }
    public func compare(to other: Self) -> IdentityComparison {
        if let a = accountId, let b = other.accountId { return a == b ? .same : .different }
        if let a = orgId, let b = other.orgId, a != b { return .different }
        if let a = email, let b = other.email { return a == b ? .same : .different }
        return .incomparable
    }
    public func merging(_ other: Self) -> Self {
        Self(accountId: other.accountId ?? accountId, orgId: other.orgId ?? orgId, email: other.email ?? email)
    }
    public var hashed: Self { Self(accountId: accountId.map { digest($0, length: 16) }, orgId: orgId.map { digest($0, length: 16) }, email: email.map { digest($0, length: 16) }) }
}
public struct AccountUsage: Codable, Hashable, Sendable {
    public var accountId: UUID
    public var identity: AccountIdentity?
    public var windows: [UsageWindow]
    public var fetchedAt: Date
    public var source: String
    public var providerIdentity: ProviderIdentity
    public init(accountId: UUID, identity: AccountIdentity? = nil, windows: [UsageWindow], fetchedAt: Date = Date(), source: String, providerIdentity: ProviderIdentity = .init()) {
        self.accountId = accountId; self.identity = identity; self.windows = windows; self.fetchedAt = fetchedAt; self.source = source; self.providerIdentity = providerIdentity
    }
    public var representative: UsageWindow? {
        windows.first(where: \.isActive) ?? windows.enumerated().sorted {
            if $0.element.percent != $1.element.percent { return $0.element.percent > $1.element.percent }
            if $0.element.durationMinutes != $1.element.durationMinutes { return ($0.element.durationMinutes ?? .max) < ($1.element.durationMinutes ?? .max) }
            return $0.offset < $1.offset
        }.first?.element
    }
    public func remainingPercent(at now: Date) -> Double? { windows.map { $0.remainingPercent(at: now) }.min() }
    public func hasUnconfirmedReset(at now: Date) -> Bool { windows.contains { $0.unconfirmedReset(at: now) } }
    /// Any unconfirmed window makes the account minimum provisional, even if another window is lower.
    public func remainingPercentText(at now: Date) -> String? {
        guard let percent = remainingPercent(at: now) else { return nil }
        return (hasUnconfirmedReset(at: now) ? "≈" : "") + "\(Int(percent.rounded()))%"
    }
}
public enum AccountState: Hashable, Sendable {
    case renewing(AccountUsage?), renewalPending(AccountUsage?), permissionRequired
    case ok(AccountUsage), stale(AccountUsage, reason: String), needsLogin, tokenInvalid(AccountUsage?), cliMissing(Provider), error(String, AccountUsage?)
    public var usage: AccountUsage? {
        switch self { case .ok(let u), .stale(let u, _): u; case .tokenInvalid(let u), .renewing(let u), .renewalPending(let u), .error(_, let u): u; default: nil }
    }
    public var message: String? {
        switch self {
        case .renewing: L("Renouvellement en cours…")
        case .renewalPending: L("Renouvellement au prochain rafraîchissement")
        case .permissionRequired: ErrorKind.permissionRequired.message
        case .ok: nil
        case .stale(_, let reason), .error(let reason, _): reason
        case .needsLogin: L("Connexion requise")
        case .tokenInvalid: L("Jeton expiré ou rejeté : reconnectez-vous")
        case .cliMissing(let p): p.title + " — " + L("CLI introuvable")
        }
    }
    public var isRenewing: Bool { if case .renewing = self { true } else { false } }
    public var offersReconnect: Bool {
        switch self { case .ok, .renewing, .renewalPending, .permissionRequired: false; default: true }
    }
    public var isOK: Bool { if case .ok = self { true } else { false } }
    public var category: String {
        switch self { case .renewing: "renewing"; case .renewalPending: "renewalPending"; case .permissionRequired: "permissionRequired"; case .ok: "ok"; case .stale: "stale"; case .needsLogin: "needsLogin"; case .tokenInvalid: "tokenInvalid"; case .cliMissing: "cliMissing"; case .error: "error" }
    }
}
public enum ErrorKind: String, Error, Codable, Sendable {
    case timeout, process, malformed, network, needsLogin, tokenInvalid, missingScope, policy, rateLimited, server, cancelled, storage, invalidConfig, quotaUnavailable, accessDenied, permissionRequired
    public var message: String {
        switch self {
        case .timeout: L("Délai dépassé")
        case .process: L("Le CLI a échoué")
        case .malformed: L("Réponse du fournisseur non reconnue")
        case .network: L("Réseau indisponible")
        case .needsLogin: L("Connexion requise")
        case .tokenInvalid: L("Jeton expiré ou rejeté : reconnectez-vous")
        case .missingScope: L("Jeton sans portée profil : reconnectez-vous avec claude auth login")
        case .permissionRequired: L("Autorisez la lecture des quotas Cursor dans les réglages du compte.")
        case .accessDenied: L("Accès refusé par le fournisseur")
        case .policy: L("Accès refusé par le fournisseur — pause de 6 h")
        case .rateLimited: L("Trop de requêtes — nouvelle tentative différée")
        case .server: L("Fournisseur temporairement indisponible")
        case .cancelled: L("Opération annulée")
        case .storage: L("Impossible de lire ou écrire les réglages")
        case .quotaUnavailable: L("Quota d’abonnement indisponible pour cette session CLI")
        case .invalidConfig: L("Dossier de configuration invalide ou déjà utilisé")
        }
    }
}
public struct ProviderFailure: Error, Sendable {
    public var kind: ErrorKind
    public var retryAfter: TimeInterval?
    public var identity: ProviderIdentity?
    public init(_ kind: ErrorKind, retryAfter: TimeInterval? = nil, identity: ProviderIdentity? = nil) { self.kind = kind; self.retryAfter = retryAfter; self.identity = identity }
}
public struct Settings: Codable, Equatable, Sendable {
    public var interval: TimeInterval = 300
    public var showPercent = true
    public var notify80 = false
    public var notify100 = false
    public var perAccountMenu = false
    public var extraUsage = false
    public var language = "fr"
    public var claudeBinary = ""
    public var codexBinary = ""
    public var additionalBinaries: [String: String]?
    public init() {}
    public func binaryOverride(_ provider: Provider) -> String? {
        let value = provider == .claude ? claudeBinary : provider == .codex ? codexBinary : additionalBinaries?[provider.rawValue] ?? ""
        return value.isEmpty ? nil : value
    }
}
public enum KeychainServiceName {
    public static func name(configDir: String?, secureStorageDir: String? = nil) -> String {
        let dir = secureStorageDir ?? configDir
        guard let dir, !(secureStorageDir != nil && dir.isEmpty) else { return "Claude Code-credentials" }
        return "Claude Code-credentials-" + digest(dir.precomposedStringWithCanonicalMapping, length: 8)
    }
}
