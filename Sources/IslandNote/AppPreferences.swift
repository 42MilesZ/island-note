import Foundation

enum AppLanguage: String {
    case system, english = "en", chinese = "zh-Hans"
}

/// App features are opt-in; enabling Flomo is separate from connecting a memo.
final class AppPreferences {
    static let shared = AppPreferences(defaults: .standard, legacyStateURL: NoteStore.defaultDirectory.appendingPathComponent("flomo-sync.json"))
    static let flomoKey = "flomoExtensionEnabled"
    private let defaults: UserDefaults?
    private(set) var flomoEnabled: Bool

    init(defaults: UserDefaults?, legacyStateURL: URL? = nil) {
        self.defaults = defaults
        if defaults?.object(forKey: Self.flomoKey) == nil, let legacyStateURL,
           let data = try? Data(contentsOf: legacyStateURL),
           let record = try? JSONDecoder().decode(SyncRecord.self, from: data),
           record.memoID != nil || record.creationUncertain || record.pendingWrite != nil {
            // A prior connection is an existing opt-in. Preserve explicit off choices.
            flomoEnabled = true
            defaults?.set(true, forKey: Self.flomoKey)
        } else { flomoEnabled = defaults?.bool(forKey: Self.flomoKey) ?? false }
    }

    func setFlomoEnabled(_ enabled: Bool) {
        flomoEnabled = enabled
        defaults?.set(enabled, forKey: Self.flomoKey)
    }
}
