import Foundation

enum AppLanguage: String, CaseIterable {
    case system, english = "en", chinese = "zh-Hans"

    var title: String {
        switch self {
        case .system: return L10n.tr("Follow System")
        case .english: return "English"
        case .chinese: return "简体中文"
        }
    }
}

/// App features are opt-in; enabling Flomo is separate from connecting a memo.
final class AppPreferences {
    static let shared = AppPreferences(defaults: .standard)
    static let flomoKey = "flomoExtensionEnabled"
    static let languageKey = "appLanguage"
    private let defaults: UserDefaults?
    private(set) var flomoEnabled: Bool
    private(set) var language: AppLanguage

    init(defaults: UserDefaults?) {
        self.defaults = defaults
        flomoEnabled = defaults?.bool(forKey: Self.flomoKey) ?? false
        language = AppLanguage(rawValue: defaults?.string(forKey: Self.languageKey) ?? "") ?? .system
    }

    func setFlomoEnabled(_ enabled: Bool) {
        flomoEnabled = enabled
        defaults?.set(enabled, forKey: Self.flomoKey)
    }

    func setLanguage(_ language: AppLanguage) {
        self.language = language
        defaults?.set(language.rawValue, forKey: Self.languageKey)
        L10n.language = language
    }
}
