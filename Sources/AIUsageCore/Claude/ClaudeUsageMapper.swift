import Foundation

public struct ClaudeUsageResponse: Decodable, Sendable {
    public struct Legacy: Decodable, Sendable { var utilization: Double?; var resets_at: String?; var locked_reason: String?; var display_name: String? }
    public struct Limit: Decodable, Sendable {
        struct Scope: Decodable, Sendable { struct Model: Decodable, Sendable { var id: String?; var display_name: String? }; var model: Model?; var surface: String? }
        var kind: String; var percent: Double?; var resets_at: String?; var severity: String?; var is_active: Bool?; var scope: Scope?
    }
    public struct Extra: Decodable, Sendable { var is_enabled: Bool?; var utilization: Double? }
    var five_hour: Legacy?; var seven_day: Legacy?; var limits: [Limit]?; var extra_usage: Extra?
    var additionalQuotas: [String: Legacy] = [:]
    private enum CodingKeys: String, CodingKey { case five_hour, seven_day, limits, extra_usage }
    private struct QuotaKey: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }
    public init(from decoder: Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        five_hour = try fields.decodeIfPresent(Legacy.self, forKey: .five_hour)
        seven_day = try fields.decodeIfPresent(Legacy.self, forKey: .seven_day)
        limits = try fields.decodeIfPresent([Limit].self, forKey: .limits)
        extra_usage = try fields.decodeIfPresent(Extra.self, forKey: .extra_usage)
        let allFields = try decoder.container(keyedBy: QuotaKey.self)
        for key in allFields.allKeys where CodingKeys(rawValue: key.stringValue) == nil {
            // Recognize the provider's quota shape, not a fixed list of model names.
            guard let quota = try? allFields.decode(Legacy.self, forKey: key),
                  let percent = quota.utilization, percent.isFinite else { continue }
            additionalQuotas[key.stringValue] = quota
        }
    }
}
public enum ClaudeUsageMapper {
    public static func date(_ string: String?) -> Date? {
        guard let string else { return nil }
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: string) { return date }
        formatter.formatOptions = [.withInternetDateTime]; return formatter.date(from: string)
    }
    private static func slug(_ string: String) -> String {
        string.lowercased().unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? String($0) : "-" }.joined()
    }
    public static func map(_ response: ClaudeUsageResponse, includeExtras: Bool = false) -> [UsageWindow] {
        var windows: [UsageWindow] = []
        if let limits = response.limits, !limits.isEmpty {
            for limit in limits {
                guard let percent = limit.percent, percent.isFinite else { continue }
                let model = limit.scope?.model
                let scope = model?.display_name ?? limit.scope?.surface
                let label: String
                let duration: Int?
                switch limit.kind {
                case "session": label = L("Session 5 h"); duration = 300
                case "weekly_all": label = L("Semaine"); duration = 10080
                case "weekly_scoped": label = L("Semaine") + (scope.map { " · " + $0 } ?? ""); duration = 10080
                default: label = limit.kind.replacingOccurrences(of: "_", with: " ").capitalized; duration = nil
                }
                var severity: Severity
                switch limit.severity {
                case "blocked": severity = .blocked
                case "normal": severity = .normal
                case "warning": severity = .warning
                case "critical", "exceeded", "limit_reached": severity = .critical
                default: severity = .threshold(percent)
                }
                let locked = limit.kind == "session" ? response.five_hour?.locked_reason : limit.kind == "weekly_all" ? response.seven_day?.locked_reason : nil
                if percent >= 100 || locked != nil { severity = .blocked }
                let id = "claude:\(limit.kind):\(slug(model?.id ?? model?.display_name ?? "")):\(slug(limit.scope?.surface ?? ""))"
                windows.append(.init(id: id, label: label, percent: percent, resetsAt: date(limit.resets_at), durationMinutes: duration, severity: severity, isActive: limit.is_active ?? false))
            }
        } else {
            for (kind, value, duration) in [("session", response.five_hour, 300), ("weekly_all", response.seven_day, 10080)] {
                guard let value, let percent = value.utilization, percent.isFinite else { continue }
                windows.append(.init(id: "claude:\(kind)::", label: CodexRateLimitsMapper.windowLabel(duration), percent: percent,
                                     resetsAt: date(value.resets_at), durationMinutes: duration, severity: value.locked_reason != nil ? .blocked : .threshold(percent)))
            }
            for key in response.additionalQuotas.keys.sorted() {
                guard let value = response.additionalQuotas[key], let percent = value.utilization else { continue }
                let weekly = key.hasPrefix("seven_day_")
                let scope = weekly ? String(key.dropFirst("seven_day_".count)) : key
                let name = value.display_name ?? scope.replacingOccurrences(of: "_", with: " ").capitalized
                let id = weekly ? "claude:weekly_scoped:\(slug(scope)):" : "claude:legacy:\(key)"
                windows.append(.init(id: id, label: weekly ? L("Semaine") + " · " + name : name,
                                     percent: percent, resetsAt: date(value.resets_at), durationMinutes: weekly ? 10080 : nil,
                                     severity: value.locked_reason != nil ? .blocked : .threshold(percent)))
            }
        }
        if includeExtras, response.extra_usage?.is_enabled == true, let percent = response.extra_usage?.utilization {
            windows.append(.init(id: "claude:extra_usage::", label: L("Crédits supplémentaires"), percent: percent))
        }
        return windows
    }
}
