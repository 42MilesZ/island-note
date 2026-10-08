import Foundation

enum AppLanguage: String {
    case system, english = "en", chinese = "zh-Hans"
}

/// App features are opt-in; enabling Flomo is separate from connecting a memo.
final class AppPreferences {
    static let shared = AppPreferences(defaults: .standard)
    static let flomoKey = "flomoExtensionEnabled"
    private let defaults: UserDefaults?
    private(set) var flomoEnabled: Bool

    init(defaults: UserDefaults?) {
        self.defaults = defaults
        flomoEnabled = defaults?.bool(forKey: Self.flomoKey) ?? false
    }

    func setFlomoEnabled(_ enabled: Bool) {
        flomoEnabled = enabled
        defaults?.set(enabled, forKey: Self.flomoKey)
    }
}
