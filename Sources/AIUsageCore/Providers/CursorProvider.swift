import Foundation

public struct CursorQuotaResponse: Decodable, Sendable {
    public struct Pool: Decodable, Sendable {
        var enabled: Bool?; var used: Double?; var limit: Double?
        var autoPercentUsed: Double?; var apiPercentUsed: Double?; var totalPercentUsed: Double?
    }
    public struct Individual: Decodable, Sendable { var plan: Pool?; var overall: Pool? }
    public struct Team: Decodable, Sendable { var pooled: Pool? }
    var billingCycleEnd: String?; var membershipType: String?; var isUnlimited: Bool?
    var individualUsage: Individual?; var teamUsage: Team?
    public func windows() throws -> [UsageWindow] {
        var windows: [UsageWindow] = []
        let reset = QuotaDate.parse(billingCycleEnd)
        func add(_ id: String, _ label: String, _ used: Double?) throws {
            guard let used else { return }
            guard used.isFinite, used >= 0 else { throw ErrorKind.malformed }
            windows.append(.init(id: "cursor:" + id, label: label, percent: used, resetsAt: reset))
        }
        func percent(_ pool: Pool) -> Double? {
            guard pool.enabled != false else { return nil }
            if let used = pool.used, let limit = pool.limit, limit > 0 { return 100 * used / limit }
            return pool.totalPercentUsed
        }
        if let plan = individualUsage?.plan, plan.enabled != false, isUnlimited != true {
            try add("auto", "Auto / Composer", plan.autoPercentUsed)
            try add("api", L("Modèles nommés"), plan.apiPercentUsed)
            if windows.isEmpty { try add("plan", L("Abonnement"), percent(plan)) }
        }
        if let overall = individualUsage?.overall { try add("overall", L("Plafond individuel"), percent(overall)) }
        if windows.isEmpty, let pooled = teamUsage?.pooled { try add("team", L("Quota de l’équipe"), percent(pooled)) }
        guard !windows.isEmpty else { throw ErrorKind.quotaUnavailable }
        return windows
    }
}
public struct CursorCredential: Sendable {
    var cookie: String
    var identity: ProviderIdentity
    public init(data: Data, now: Date = Date()) throws {
        struct Auth: Decodable { var accessToken: String }
        guard let auth = try? JSONDecoder().decode(Auth.self, from: data) else { throw ErrorKind.needsLogin }
        let pieces = auth.accessToken.split(separator: ".", omittingEmptySubsequences: false)
        guard pieces.count == 3 else { throw ErrorKind.needsLogin }
        var payload = String(pieces[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
        struct Claims: Decodable { var sub: String; var email: String?; var exp: Double? }
        guard let bytes = Data(base64Encoded: payload), let claims = try? JSONDecoder().decode(Claims.self, from: bytes),
              let user = claims.sub.split(separator: "|").last, !user.isEmpty else { throw ErrorKind.needsLogin }
        if let expiry = claims.exp, expiry <= now.addingTimeInterval(60).timeIntervalSince1970 { throw ErrorKind.needsLogin }
        let safe = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
        guard user.unicodeScalars.allSatisfy(safe.contains), auth.accessToken.unicodeScalars.allSatisfy(safe.contains) else { throw ErrorKind.needsLogin }
        identity = .init(accountId: String(user), email: claims.email)
        cookie = "WorkosCursorSessionToken=" + user + "%3A%3A" + auth.accessToken
    }
}
public protocol CursorCredentialReading: Sendable { func read() throws -> CursorCredential }
public struct CursorCredentialReader: CursorCredentialReading {
    public init() {}
    public func read() throws -> CursorCredential {
        let home = FileManager.default.homeDirectoryForCurrentUser
        // Cursor CLI state only. Do not import a browser or the editor's potentially different account.
        let candidates = ["Library/Application Support/cursor/auth.json", ".config/cursor/auth.json"]
        guard let path = candidates.map({ home.appendingPathComponent($0) }).first(where: { FileManager.default.fileExists(atPath: $0.path) }) else { throw ErrorKind.needsLogin }
        guard let data = try? Data(contentsOf: path), data.count < 1024 * 1024 else { throw ErrorKind.needsLogin }
        return try CursorCredential(data: data)
    }
}
public struct CursorProvider: UsageProvider {
    private let credentials: any CursorCredentialReading
    private let http: any HTTPClient
    public init(credentials: any CursorCredentialReading = CursorCredentialReader(), http: any HTTPClient = URLSessionHTTPClient()) { self.credentials = credentials; self.http = http }
    public func fetch(account: Account, binary: String, includeExtras: Bool = false, forceIdentity: Bool = false) async throws -> AccountUsage {
        guard account.cursorWebUsageEnabled == true else { throw ErrorKind.permissionRequired }
        let credential = try credentials.read()
        do {
            var request = URLRequest(url: URL(string: "https://cursor.com/api/usage-summary")!)
            request.timeoutInterval = 20; request.cachePolicy = .reloadIgnoringLocalCacheData
            request.setValue(credential.cookie, forHTTPHeaderField: "Cookie")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            let response = try await http.get(request)
            switch response.status {
            case 200: break
            case 401: throw ErrorKind.tokenInvalid
            case 403: throw ErrorKind.policy
            case 429: throw ProviderFailure(.rateLimited, retryAfter: ClaudeProvider.retryAfter(response.retryAfter), identity: credential.identity)
            case 500...599: throw ErrorKind.server
            default: throw ErrorKind.quotaUnavailable
            }
            let quota = try JSONDecoder().decode(CursorQuotaResponse.self, from: response.data)
            return .init(accountId: account.id, identity: .init(email: credential.identity.email, plan: quota.membershipType), windows: try quota.windows(), source: "cursor-cli-session", providerIdentity: credential.identity)
        } catch {
            if let failure = error as? ProviderFailure { throw failure }
            throw ProviderFailure(error as? ErrorKind ?? .malformed, identity: credential.identity)
        }
    }
}
