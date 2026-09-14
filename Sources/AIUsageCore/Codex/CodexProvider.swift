import Foundation

public protocol UsageProvider: Sendable {
    func fetch(account: Account, binary: String, includeExtras: Bool, forceIdentity: Bool) async throws -> AccountUsage
}
public struct CodexAccountResponse: Decodable, Sendable {
    public struct Info: Decodable, Sendable { public var type: String; public var email: String?; public var planType: String? }
    public var account: Info?
}
public struct CodexRateLimits: Decodable, Sendable {
    public struct Window: Decodable, Sendable { public var usedPercent: Double; public var windowDurationMins: Int?; public var resetsAt: Double? }
    public struct Snapshot: Decodable, Sendable {
        public var limitId: String?; public var limitName: String?
        public var primary: Window?; public var secondary: Window?
        public var rateLimitReachedType: String?; public var planType: String?; public var spendControlReached: Bool?
    }
    public var rateLimits: Snapshot
    public var rateLimitsByLimitId: [String: Snapshot]?
    public var ordinaryUsageAllowed: Bool?
    public var accountId: String?
}
public enum CodexRateLimitsMapper {
    public static func map(_ response: CodexRateLimits) -> [UsageWindow] {
        let snapshots = response.rateLimitsByLimitId.flatMap { $0.isEmpty ? nil : $0 } ?? [response.rateLimits.limitId ?? "codex": response.rateLimits]
        var windows: [UsageWindow] = []
        for key in snapshots.keys.sorted(by: { $0 == "codex" ? $1 != "codex" : $1 == "codex" ? false : $0 < $1 }) {
            guard let snapshot = snapshots[key] else { continue }
            for (kind, value) in [("primary", snapshot.primary), ("secondary", snapshot.secondary)] {
                guard let value else { continue }
                let blocked = response.ordinaryUsageAllowed == false || snapshot.rateLimitReachedType != nil || snapshot.spendControlReached == true
                windows.append(.init(id: "codex:\(snapshot.limitId ?? key):\(kind)", label: windowLabel(value.windowDurationMins),
                                     group: key == "codex" ? nil : snapshot.limitName ?? key, percent: value.usedPercent,
                                     resetsAt: value.resetsAt.map(Date.init(timeIntervalSince1970:)), durationMinutes: value.windowDurationMins,
                                     severity: blocked ? .blocked : .threshold(value.usedPercent)))
            }
        }
        let representative = AccountUsage(accountId: UUID(), windows: windows, source: "codex-rpc").representative?.id
        for index in windows.indices { windows[index].isActive = windows[index].id == representative }
        return windows
    }
    public static func windowLabel(_ minutes: Int?, language: String? = nil) -> String {
        switch minutes { case 300: L("Session 5 h", language: language); case 10080: L("Semaine", language: language); case 1440: L("Jour", language: language)
        case .some(let n): L("Fenêtre", language: language) + " \(Int((Double(n) / 60).rounded())) h"
        case .none: L("Fenêtre", language: language) }
    }
}

public actor CodexRPCClient {
    private var session: ProcessSession?
    private var nextID = 0
    private let requestTimeout: TimeInterval
    public init(timeout: TimeInterval = 20) { requestTimeout = timeout }
    public func read(account: Account, binary: String) async throws -> AccountUsage {
        let session = try ProcessSession(executable: binary, arguments: ["app-server"], environment: account.environment)
        self.session = session
        defer { session.close(); self.session = nil }
        let _: EmptyResult = try await request("initialize", params: #"{"clientInfo":{"name":"ai-usage-widget","title":"AI Usage Widget","version":"1.0.0"}}"#)
        try session.send(Data(#"{"method":"initialized"}"#.utf8) + Data([10]))
        let accountResult: CodexAccountResponse = try await request("account/read", params: #"{"refreshToken":false}"#)
        guard let info = accountResult.account else { throw ProviderFailure(.needsLogin) }
        let identity = ProviderIdentity(email: info.email)
        if info.type.lowercased() == "apikey" {
            return .init(accountId: account.id, identity: .init(plan: "apiKey"), windows: [], source: "codex-rpc")
        }
        do {
            let response: CodexRateLimits = try await request("account/rateLimits/read", params: #"{"excludeResetCreditDetails":true}"#)
            return .init(accountId: account.id, identity: .init(email: info.email, plan: info.planType ?? response.rateLimits.planType),
                         windows: CodexRateLimitsMapper.map(response), source: "codex-rpc", providerIdentity: .init(accountId: response.accountId, email: info.email))
        } catch {
            if var failure = error as? ProviderFailure { failure.identity = identity; throw failure }
            throw ProviderFailure(error as? ErrorKind ?? .network, identity: identity)
        }
    }
    private struct EmptyResult: Decodable, Sendable {}
    private struct Envelope<T: Decodable>: Decodable { var id: Int?; var result: T?; var error: RPCError? }
    private struct RPCError: Decodable { var code: Int; var message: String? }
    private func request<T: Decodable & Sendable>(_ method: String, params: String) async throws -> T {
        guard let session else { throw ErrorKind.process }
        let id = nextID; nextID += 1
        try session.send(Data("{\"method\":\"\(method)\",\"id\":\(id),\"params\":\(params)}\n".utf8))
        let deadline = Date().addingTimeInterval(requestTimeout)
        while true {
            let line = try await session.nextLine(timeout: max(0, deadline.timeIntervalSinceNow))
            // Inspect only the envelope first: unsolicited messages may have unrelated payload shapes.
            guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { throw ErrorKind.malformed }
            guard object["id"] as? Int == id else { continue }
            if let rpc = object["error"] as? [String: Any] {
                let message = (rpc["message"] as? String ?? "").lowercased()
                throw ProviderFailure(message.contains("auth") || message.contains("log in") ? .needsLogin : .server)
            }
            do {
                guard let result = try JSONDecoder().decode(Envelope<T>.self, from: line).result else { throw ErrorKind.malformed }
                return result
            } catch { throw ErrorKind.malformed }
        }
    }
}
public actor CodexProvider: UsageProvider {
    public init() {}
    public func fetch(account: Account, binary: String, includeExtras: Bool = false, forceIdentity: Bool = false) async throws -> AccountUsage {
        try await CodexRPCClient().read(account: account, binary: binary)
    }
}
