import Foundation

public enum AppLanguage: String, CaseIterable, Sendable {
    case french = "fr", english = "en", italian = "it", spanish = "es", german = "de", portuguese = "pt-BR"

    public var nativeName: String {
        switch self {
        case .french: "Français"
        case .english: "English"
        case .italian: "Italiano"
        case .spanish: "Español"
        case .german: "Deutsch"
        case .portuguese: "Português (Brasil)"
        }
    }
}
