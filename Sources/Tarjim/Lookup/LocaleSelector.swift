import Foundation

struct LocaleSelection: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        /// The user's own language.
        case user
        /// The app's fallback language, served because the release has none of the user's.
        case fallback
    }

    let kind: Kind
    /// Manifest locale keys, verbatim, most specific first.
    let locales: [String]
}

enum LocaleSelector {
    static func select(available: [String], preferences: [String], appLanguage: String,
                       override: String?, fallbackLanguage: String) -> LocaleSelection? {
        if let override, let key = available.first(where: { $0.caseInsensitiveCompare(override) == .orderedSame }) {
            let locales = match(preference: key, available: available)
            if !locales.isEmpty { return LocaleSelection(kind: .user, locales: locales) }
        }
        for preference in preferenceList(preferences: preferences, appLanguage: appLanguage) {
            let locales = match(preference: preference, available: available)
            if !locales.isEmpty { return LocaleSelection(kind: .user, locales: locales) }
        }
        let locales = match(preference: fallbackLanguage, available: available)
        return locales.isEmpty ? nil : LocaleSelection(kind: .fallback, locales: locales)
    }

    static func preferenceList(preferences: [String], appLanguage: String) -> [String] {
        preferences.filter { sameLanguageAndScript($0, appLanguage) } + [appLanguage]
    }

    static func match(preference: String, available: [String]) -> [String] {
        guard !available.isEmpty else { return [] }
        let answer = Bundle.preferredLocalizations(from: available, forPreferences: [preference])
        guard let first = answer.first, sameLanguageAndScript(first, preference) else { return [] }
        return answer
    }

    // Apple's matcher falls back to whatever is left (e.g. `en`) when nothing fits, so its answer
    // only counts when it is the same language and script as what was asked for.
    private static func sameLanguageAndScript(_ a: String, _ b: String) -> Bool {
        let x = parts(a), y = parts(b)
        guard x.language == y.language else { return false }
        if #available(iOS 16, macOS 13, *) { return x.script == y.script }
        // iOS 15 has no likely-subtags lookup, so only explicit scripts can disagree.
        if let sx = x.script, let sy = y.script { return sx == sy }
        return true
    }

    // Canonicalised first: `Locale.Language` keeps legacy codes such as `iw` and `no` as written.
    private static func parts(_ identifier: String) -> (language: String?, script: String?) {
        let canonical = Locale.canonicalLanguageIdentifier(from: identifier)
        if #available(iOS 16, macOS 13, *) {
            let language = Locale.Language(identifier: canonical)
            let maximal = Locale.Language(identifier: language.maximalIdentifier)
            return (language.languageCode?.identifier, maximal.script?.identifier)
        }
        let components = Locale.components(fromIdentifier: canonical.replacingOccurrences(of: "-", with: "_"))
        return (components[NSLocale.Key.languageCode.rawValue], components[NSLocale.Key.scriptCode.rawValue])
    }
}
