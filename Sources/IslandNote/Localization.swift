import Foundation

enum L10n {
    static var language = AppLanguage(rawValue: UserDefaults.standard.string(forKey: AppPreferences.languageKey) ?? "") ?? .system

    private static var resourceBundle: Bundle {
        #if SWIFT_PACKAGE
        if let resources = Bundle.main.resourceURL,
           let bundled = Bundle(url: resources.appendingPathComponent("IslandNote_IslandNote.bundle")) { return bundled }
        return .module
        #else
        return .main
        #endif
    }

    static func bundle(language: AppLanguage? = nil) -> Bundle {
        let selection = language ?? self.language
        let code: String
        switch selection {
        case .chinese: code = "zh-Hans"
        case .english: code = "en"
        case .system: code = Locale.preferredLanguages.first?.hasPrefix("zh") == true ? "zh-Hans" : "en"
        }
        // SwiftPM normalizes localization folder names; Xcode preserves their case.
        for name in [code, code.lowercased()] {
            if let url = resourceBundle.resourceURL?.appendingPathComponent(name + ".lproj"),
               FileManager.default.fileExists(atPath: url.path), let bundle = Bundle(url: url) { return bundle }
        }
        return resourceBundle
    }

    static func tr(_ key: String, language: AppLanguage? = nil) -> String {
        bundle(language: language).localizedString(forKey: key, value: key, table: nil)
    }

    static func format(_ key: String, _ arguments: CVarArg...) -> String {
        String(format: tr(key), locale: Locale.current, arguments: arguments)
    }

    static func resource(_ name: String, extension ext: String) -> URL? {
        bundle().url(forResource: name, withExtension: ext)
    }
}
