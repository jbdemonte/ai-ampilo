import Foundation

extension UsageWindow {
    /// Derive widget-owned text at display time, including data restored from an older-language cache.
    /// Provider model names and unknown future quota labels remain untouched.
    public func displayLabel(language: String? = nil) -> String {
        func localized(_ key: String) -> String { L(key, language: language) }
        if id.hasPrefix("codex:") { return CodexRateLimitsMapper.windowLabel(durationMinutes, language: language) }
        if id.hasPrefix("claude:session:") { return localized("Session 5 h") }
        if id.hasPrefix("claude:weekly_all:") { return localized("Semaine") }
        if id.hasPrefix("claude:weekly_scoped:") {
            let suffix = label.range(of: " · ").map { String(label[$0.lowerBound...]) } ?? ""
            return localized("Semaine") + suffix
        }
        if id.hasPrefix("claude:extra_usage:") { return localized("Crédits supplémentaires") }
        switch id {
        case "gemini:daily": return localized("Quota quotidien")
        case "grok:subscription": return localized(durationMinutes == 10080 ? "Semaine" : "Abonnement")
        case "copilot:premium_interactions": return localized("Requêtes premium")
        case "copilot:chat": return localized("Chat")
        case "copilot:completions": return localized("Complétions")
        case "cursor:api": return localized("Modèles nommés")
        case "cursor:plan": return localized("Abonnement")
        case "cursor:overall": return localized("Plafond individuel")
        case "cursor:team": return localized("Quota de l’équipe")
        default: return label
        }
    }
}
