import Foundation

public struct ClaudeCredential: Decodable, Sendable {
    public var accessToken: String
    public var refreshToken: String?
    public var expiresAt: Double
    public var scopes: [String]?
    public var subscriptionType: String?
    public var rateLimitTier: String?
    public var tokenHash: String { digest(accessToken) }
    public var expires: Date { Date(timeIntervalSince1970: expiresAt / 1000) }
    public var identityFingerprint: String { digest([refreshToken ?? "", subscriptionType ?? "", rateLimitTier ?? "", (scopes ?? []).sorted().joined(separator: ",")].joined(separator: "\n")) }
}
public protocol CredentialReading: Sendable { func read(account: Account) async throws -> ClaudeCredential }
public struct KeychainReader: CredentialReading {
    private let runner: any ProcessRunning
    public init(runner: any ProcessRunning = ProcessRunner()) { self.runner = runner }
    public func read(account: Account) async throws -> ClaudeCredential {
        let result = try await runner.run("/usr/bin/security", arguments: ["find-generic-password", "-s", account.keychainService, "-w"], environment: [:], timeout: 10)
        if result.exitCode == 44 { throw ErrorKind.needsLogin }
        guard result.exitCode == 0 else { throw ErrorKind.process }
        struct Item: Decodable { var claudeAiOauth: ClaudeCredential? }
        guard let item = try? JSONDecoder().decode(Item.self, from: result.stdout) else { throw ErrorKind.malformed }
        guard let credential = item.claudeAiOauth else { throw ErrorKind.needsLogin }
        guard credential.scopes?.contains("user:profile") == true else { throw ErrorKind.missingScope }
        return credential
    }
    public struct Service: Identifiable, Sendable { public var name: String; public var modified: Date?; public var id: String { name } }
    public func services() async throws -> [Service] {
        let result = try await runner.run("/usr/bin/security", arguments: ["dump-keychain"], environment: [:], timeout: 15)
        guard result.exitCode == 0 else { throw ErrorKind.process }
        let text = String(decoding: result.stdout, as: UTF8.self)
        var services: [Service] = []
        for block in text.components(separatedBy: "keychain:") {
            guard let expression = try? NSRegularExpression(pattern: #"\"svce\"<blob>=\"(Claude Code-credentials[^\"]*)\""#),
                  let match = expression.firstMatch(in: block, range: NSRange(block.startIndex..., in: block)),
                  let range = Range(match.range(at: 1), in: block) else { continue }
            let modified = Self.modificationDate(in: block)
            services.append(.init(name: String(block[range]), modified: modified))
        }
        return services.sorted { $0.name < $1.name }
    }
    public static func modificationDate(in block: String) -> Date? {
        guard let regex = try? NSRegularExpression(pattern: #"\"mdat\"[^\n]*?\"([0-9]{14})Z"#),
              let match = regex.firstMatch(in: block, range: NSRange(block.startIndex..., in: block)),
              let range = Range(match.range(at: 1), in: block) else { return nil }
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0); formatter.dateFormat = "yyyyMMddHHmmss"
        return formatter.date(from: String(block[range]))
    }

}

public struct HTTPResult: Sendable { public var data: Data; public var status: Int; public var retryAfter: String? }
public protocol HTTPClient: Sendable { func get(_ request: URLRequest) async throws -> HTTPResult }
private final class NoCredentialRedirect: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
public struct URLSessionHTTPClient: HTTPClient {
    public init() {}
    public func get(_ request: URLRequest) async throws -> HTTPResult {
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false; config.httpCookieStorage = nil; config.urlCache = nil
        let session = URLSession(configuration: config, delegate: NoCredentialRedirect(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        do {
            let (data, response) = try await session.data(for: request)
            guard let response = response as? HTTPURLResponse else { throw ErrorKind.malformed }
            return .init(data: data, status: response.statusCode, retryAfter: response.value(forHTTPHeaderField: "Retry-After"))
        } catch let error as URLError { throw error.code == .timedOut ? ErrorKind.timeout : ErrorKind.network }
    }
}
public struct ClaudeAuthStatus: Decodable, Sendable {
    public var loggedIn: Bool; public var email: String?; public var orgId: String?; public var subscriptionType: String?
    public var identity: ProviderIdentity { .init(orgId: orgId, email: email) }
}
public actor ClaudeProvider: UsageProvider {
    private let credentials: any CredentialReading
    private let runner: any ProcessRunning
    private let http: any HTTPClient
    private var rejected: [UUID: String] = [:]
    private var invalidStart: [UUID: String] = [:]
    private var statuses: [UUID: (ClaudeAuthStatus, Date, String)] = [:]
    private var versions: [String: (String, Date)] = [:]
    public init(credentials: any CredentialReading = KeychainReader(), runner: any ProcessRunning = ProcessRunner(), http: any HTTPClient = URLSessionHTTPClient()) {
        self.credentials = credentials; self.runner = runner; self.http = http
    }
    public func version(binary: String) async -> String {
        if let cached = versions[binary], Date().timeIntervalSince(cached.1) < 86400 { return cached.0 }
        let result = try? await runner.run(binary, arguments: ["--version"], environment: [:], timeout: 5)
        let candidate = result.map { String(decoding: $0.stdout, as: UTF8.self).split(separator: " ").first.map(String.init) ?? "" } ?? ""
        let version = candidate.range(of: #"^\d+\.\d+\.\d+$"#, options: .regularExpression) == nil ? "2.1.270" : candidate
        versions[binary] = (version, Date()); return version
    }
    public func fetch(account: Account, binary: String, includeExtras: Bool = false, forceIdentity: Bool = false) async throws -> AccountUsage {
        let credential = try await credentials.read(account: account)
        let id = account.id
        var identity: ProviderIdentity?
        do {
            let cached = statuses[id]
            if forceIdentity || cached == nil || Date().timeIntervalSince(cached!.1) >= 3600 || cached!.2 != credential.identityFingerprint {
                let result = try await runner.run(binary, arguments: ["auth", "status", "--json"], environment: account.environment, timeout: 10)
                guard let status = try? JSONDecoder().decode(ClaudeAuthStatus.self, from: result.stdout) else { throw ErrorKind.malformed }
                guard status.loggedIn else { statuses[id] = nil; throw ErrorKind.needsLogin }
                statuses[id] = (status, Date(), credential.identityFingerprint)
            }
            identity = statuses[id]?.0.identity
            if let start = invalidStart[id], Self.refreshSucceeded(credential, startingHash: start, rejectedHash: rejected[id], now: Date()) { invalidStart[id] = nil }
            if credential.expires.timeIntervalSinceNow < 120 || rejected[id] == credential.tokenHash || invalidStart[id] != nil {
                if invalidStart[id] == nil { invalidStart[id] = credential.tokenHash }
                throw ErrorKind.tokenInvalid
            }
            var request = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
            request.timeoutInterval = 20; request.cachePolicy = .reloadIgnoringLocalCacheData
            request.setValue("Bearer " + credential.accessToken, forHTTPHeaderField: "Authorization")
            request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
            request.setValue("claude-code/" + (await version(binary: binary)), forHTTPHeaderField: "User-Agent")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            let result = try await http.get(request)
            switch result.status {
            case 200: break
            case 401: rejected[id] = credential.tokenHash; invalidStart[id] = credential.tokenHash; throw ErrorKind.tokenInvalid
            case 403: throw Self.forbiddenError(result.data)
            case 429: throw ProviderFailure(.rateLimited, retryAfter: Self.retryAfter(result.retryAfter), identity: identity)
            case 500...599: throw ErrorKind.server
            default: throw ErrorKind.malformed
            }
            guard let response = try? JSONDecoder().decode(ClaudeUsageResponse.self, from: result.data) else { throw ErrorKind.malformed }
            return .init(accountId: id, identity: .init(email: identity?.email, plan: credential.subscriptionType, tier: credential.rateLimitTier),
                         windows: ClaudeUsageMapper.map(response, includeExtras: includeExtras), source: "claude-oauth-usage", providerIdentity: identity ?? .init())
        } catch {
            if let error = error as? ProviderFailure { throw error }
            throw ProviderFailure(error as? ErrorKind ?? .network, identity: identity)
        }
    }
    public static func forbiddenError(_ data: Data) -> ErrorKind {
        // Inspect the documented error message only; never expose the raw response.
        struct Response: Decodable { struct Detail: Decodable { var message: String? }; var error: Detail?; var message: String? }
        let response = try? JSONDecoder().decode(Response.self, from: data)
        let message = response?.error?.message ?? response?.message ?? ""
        return message.lowercased().contains("only authorized for use with claude code") ? .policy : .accessDenied
    }
    public func renewalContext(account: Account) async throws -> (String, String?) {
        let credential = try await credentials.read(account: account)
        return (invalidStart[account.id] ?? credential.tokenHash, rejected[account.id])
    }
    public func hadUnauthorized(_ account: Account) -> Bool { rejected[account.id] != nil }
    public static func refreshSucceeded(_ credential: ClaudeCredential, startingHash: String, rejectedHash: String?, now: Date) -> Bool {
        credential.tokenHash != startingHash && credential.tokenHash != rejectedHash && credential.expires > now.addingTimeInterval(120)
    }
    public static func retryAfter(_ value: String?, now: Date = Date()) -> TimeInterval? {
        guard let value else { return nil }
        if let seconds = Double(value) { return max(0, seconds) }
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss z"
        return formatter.date(from: value).map { max(0, $0.timeIntervalSince(now)) }
    }
}
