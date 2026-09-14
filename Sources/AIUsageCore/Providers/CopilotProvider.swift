import Foundation

public struct CopilotQuotaResponse: Decodable, Sendable {
    public struct Snapshot: Decodable, Sendable {
        var isUnlimitedEntitlement: Bool?; var entitlementRequests: Double?
        var usedRequests: Double?; var remainingPercentage: Double?; var resetDate: String?
    }
    var quotaSnapshots: [String: Snapshot]
    public func windows() throws -> [UsageWindow] {
        var result: [UsageWindow] = []
        for key in quotaSnapshots.keys.sorted() {
            guard let quota = quotaSnapshots[key], quota.isUnlimitedEntitlement != true, quota.entitlementRequests != -1 else { continue }
            let used: Double
            if let remaining = quota.remainingPercentage { used = 100 - remaining }
            else if let limit = quota.entitlementRequests, limit > 0, let value = quota.usedRequests { used = 100 * value / limit }
            else { continue }
            guard used.isFinite, used >= 0 else { throw ErrorKind.malformed }
            let label: String = switch key { case "premium_interactions": L("Requêtes premium"); case "chat": L("Chat"); case "completions": L("Complétions"); default: key }
            result.append(.init(id: "copilot:" + key, label: label, percent: used, resetsAt: QuotaDate.parse(quota.resetDate)))
        }
        guard !result.isEmpty else { throw ErrorKind.quotaUnavailable }
        return result
    }
}
public struct CopilotProvider: UsageProvider {
    public init() {}
    public func fetch(account: Account, binary: String, includeExtras: Bool = false, forceIdentity: Bool = false) async throws -> AccountUsage {
        let rpc = try QuotaRPC(binary: binary, arguments: ["--headless", "--stdio", "--no-auto-update"], environment: account.environment, framing: .contentLength)
        defer { rpc.close() }
        struct Auth: Decodable { var isAuthenticated: Bool; var login: String?; var host: String?; var copilotPlan: String? }
        let auth = try JSONDecoder().decode(Auth.self, from: await rpc.request("auth.getStatus"))
        guard auth.isAuthenticated else { throw ErrorKind.needsLogin }
        let identity = ProviderIdentity(accountId: auth.login.map { (auth.host ?? "github.com") + ":" + $0 })
        do {
            let quota = try JSONDecoder().decode(CopilotQuotaResponse.self, from: await rpc.request("account.getQuota"))
            return .init(accountId: account.id, identity: .init(plan: auth.copilotPlan), windows: try quota.windows(), source: "copilot-cli-quota", providerIdentity: identity)
        } catch { throw ProviderFailure(error as? ErrorKind ?? .malformed, identity: identity) }
    }
}
