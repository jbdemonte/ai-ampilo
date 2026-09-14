import Foundation

public struct GrokQuotaResponse: Decodable, Sendable {
    public struct Period: Decodable, Sendable { var type: String?; var start: String?; var end: String? }
    public struct Amount: Decodable, Sendable { var val: Double? }
    public struct Config: Decodable, Sendable {
        var creditUsagePercent: Double?; var currentPeriod: Period?
        var monthlyLimit: Amount?; var used: Amount?; var billingPeriodEnd: String?
    }
    var config: Config?
    var subscription_tier: String?
    public func windows() throws -> [UsageWindow] {
        guard let config else { throw ErrorKind.quotaUnavailable }
        let used: Double
        if let value = config.creditUsagePercent { used = value }
        else if let limit = config.monthlyLimit?.val, limit > 0, let amount = config.used { used = 100 * (amount.val ?? 0) / limit }
        else { throw ErrorKind.quotaUnavailable }
        guard used.isFinite, used >= 0 else { throw ErrorKind.malformed }
        let weekly = config.currentPeriod?.type == "USAGE_PERIOD_TYPE_WEEKLY"
        let reset = QuotaDate.parse(config.currentPeriod?.end ?? config.billingPeriodEnd)
        return [.init(id: "grok:subscription", label: weekly ? L("Semaine") : L("Abonnement"), percent: used, resetsAt: reset,
                      durationMinutes: weekly ? 10080 : nil, isActive: true)]
    }
}
public struct GrokProvider: UsageProvider {
    public init() {}
    public func fetch(account: Account, binary: String, includeExtras: Bool = false, forceIdentity: Bool = false) async throws -> AccountUsage {
        let rpc = try QuotaRPC(binary: binary, arguments: ["agent", "stdio"], environment: account.environment, framing: .lines)
        defer { rpc.close() }
        _ = try await rpc.request("initialize", params: #"{"protocolVersion":1,"clientCapabilities":{},"clientInfo":{"name":"ai-usage-widget","version":"1"}}"#)
        struct Auth: Decodable { var email: String?; var principalId: String?; var organizationId: String? }
        let auth = try JSONDecoder().decode(Auth.self, from: await rpc.request("_x.ai/auth/info"))
        let identity = ProviderIdentity(accountId: auth.principalId, orgId: auth.organizationId, email: auth.email)
        do {
            let result = try JSONDecoder().decode(GrokQuotaResponse.self, from: await rpc.request("_x.ai/billing"))
            return .init(accountId: account.id, identity: .init(email: auth.email, plan: result.subscription_tier), windows: try result.windows(), source: "grok-cli-billing", providerIdentity: identity)
        } catch { throw ProviderFailure(error as? ErrorKind ?? .malformed, identity: identity) }
    }
}
