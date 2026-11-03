import Foundation

enum AppLanguage: String, CaseIterable, Identifiable {
    case system
    case uk
    case en
    case es
    case de
    case kk

    var id: String { rawValue }

    /// Native names, so the menu stays readable in every language.
    var title: String {
        switch self {
        case .system: return L10n.t("lang.auto")
        case .uk: return "Українська"
        case .en: return "English"
        case .es: return "Español"
        case .de: return "Deutsch"
        case .kk: return "Қазақша"
        }
    }

    static func resolve(preference: String, preferredLanguages: [String]) -> String {
        let supported = ["uk", "en", "es", "de", "kk"]
        if preference != "system", supported.contains(preference) { return preference }
        for raw in preferredLanguages {
            let code = raw.split(separator: "-").first.map { String($0).lowercased() } ?? raw.lowercased()
            if code == "kz" { return "kk" }
            if supported.contains(code) { return code }
        }
        return "en"
    }
}

enum L10n {
    /// Forces one language in tests. The app itself leaves this nil.
    static var testingLanguage: String?
    private static let preferenceLock = NSLock()
    private static var preference = UserDefaults.standard.string(forKey: "language") ?? AppLanguage.system.rawValue

    static func setPreference(_ value: String) {
        preferenceLock.lock()
        preference = value
        preferenceLock.unlock()
    }

    static func resolvedCode() -> String {
        if let testingLanguage { return testingLanguage }
        preferenceLock.lock()
        let stored = preference
        preferenceLock.unlock()
        return AppLanguage.resolve(preference: stored, preferredLanguages: Locale.preferredLanguages)
    }

    static var locale: Locale {
        switch resolvedCode() {
        case "uk": return Locale(identifier: "uk_UA")
        case "es": return Locale(identifier: "es_ES")
        case "de": return Locale(identifier: "de_DE")
        case "kk": return Locale(identifier: "kk_KZ")
        default: return Locale(identifier: "en_US")
        }
    }

    static func t(_ key: String, language: String? = nil) -> String {
        let code = language ?? resolvedCode()
        return L10nTable.text(code, key) ?? L10nTable.text("en", key) ?? L10nTable.text("uk", key) ?? key
    }

    static func f(_ key: String, _ args: CVarArg...) -> String {
        String(format: t(key), locale: locale, arguments: args)
    }

    static func has(_ key: String) -> Bool {
        L10nTable.text(resolvedCode(), key) != nil
            || L10nTable.text("en", key) != nil
            || L10nTable.text("uk", key) != nil
    }

    static func categoryName(_ category: CacheCategory) -> String {
        let key = "cat.\(category.id)"
        return has(key) ? t(key) : category.name
    }

    static func categoryWhy(_ category: CacheCategory) -> String {
        let key = "why.\(category.id)"
        return has(key) ? t(key) : category.consequences
    }

    static func categoryNote(_ category: CacheCategory) -> String? {
        let key = "note.\(category.id)"
        if has(key) { return t(key) }
        return category.note
    }
}
