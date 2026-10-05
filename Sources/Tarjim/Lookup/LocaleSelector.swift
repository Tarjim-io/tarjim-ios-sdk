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
        let candidates = available.filter(isPlainTag)
        if let override, let key = candidates.first(where: { $0.caseInsensitiveCompare(override) == .orderedSame }) {
            let locales = match(preference: key, available: candidates)
            if !locales.isEmpty { return LocaleSelection(kind: .user, locales: locales) }
        }
        for preference in preferenceList(preferences: preferences, appLanguage: appLanguage) {
            let locales = match(preference: preference, available: candidates)
            if !locales.isEmpty { return LocaleSelection(kind: .user, locales: locales) }
        }
        let locales = match(preference: fallbackLanguage, available: candidates)
        return locales.isEmpty ? nil : LocaleSelection(kind: .fallback, locales: locales)
    }

    static func preferenceList(preferences: [String], appLanguage: String) -> [String] {
        preferenceList(preferences: preferences, appLanguage: appLanguage, likelySubtags: hasLikelySubtags)
    }

    static func match(preference: String, available: [String]) -> [String] {
        match(preference: preference, available: available, likelySubtags: hasLikelySubtags)
    }

    // Manifest keys become folder names, so only plain locale tags are ever candidates.
    private static func isPlainTag(_ key: String) -> Bool {
        (1...64).contains(key.utf8.count) && key.utf8.allSatisfy { byte in
            (byte >= 0x30 && byte <= 0x39) || (byte >= 0x41 && byte <= 0x5A) || (byte >= 0x61 && byte <= 0x7A)
                || byte == 0x2D || byte == 0x5F
        }
    }

    // Apple's matcher falls back to whatever is left (e.g. `en`) when nothing fits, so its answer only counts
    // when it is the same language and script as what was asked for.
    private static func sameLanguageAndScript(_ a: String, _ b: String, likelySubtags: Bool) -> Bool {
        let x = parts(a, likelySubtags: likelySubtags), y = parts(b, likelySubtags: likelySubtags)
        return x.language == y.language && x.script == y.script
    }

    // Canonicalised first: `Locale.Language` keeps legacy codes such as `iw` and `no` as written.
    // With likely subtags the language is the maximal identifier's, so `mo` and `ro` agree.
    private static func parts(_ identifier: String, likelySubtags: Bool) -> (language: String?, script: String?) {
        let canonical = Locale.canonicalLanguageIdentifier(from: identifier)
        if likelySubtags, #available(iOS 16, macOS 13, *) {
            let maximal = Locale.Language(identifier: Locale.Language(identifier: canonical).maximalIdentifier)
            return (maximal.languageCode?.identifier, maximal.script?.identifier)
        }
        let components = components(canonical)
        return (components.language, components.script ?? tableScript(canonical))
    }

    private static func components(_ identifier: String) -> (language: String?, script: String?, region: String?) {
        var canonical = Locale.canonicalLanguageIdentifier(from: identifier)
        // Foundation leaves the retired `mo` (Moldovan) as written.
        if canonical == "mo" || canonical.hasPrefix("mo-") || canonical.hasPrefix("mo_") { canonical = "ro" + canonical.dropFirst(2) }
        let parsed = NSLocale.components(fromLocaleIdentifier: canonical.replacingOccurrences(of: "-", with: "_"))
        return (parsed[NSLocale.Key.languageCode.rawValue], parsed[NSLocale.Key.scriptCode.rawValue],
                parsed[NSLocale.Key.countryCode.rawValue])
    }
}

extension LocaleSelector {
    static var hasLikelySubtags: Bool {
        if #available(iOS 16, macOS 13, *) { return true }
        return false
    }

    static func match(preference: String, available: [String], likelySubtags: Bool) -> [String] {
        var remaining = available.filter(isPlainTag)
        // Apple's first answer can be in the wrong script while a right one is listed: ask again without it.
        while !remaining.isEmpty {
            let answer = Bundle.preferredLocalizations(from: remaining, forPreferences: [preference])
            guard let first = answer.first else { return [] }
            if sameLanguageAndScript(first, preference, likelySubtags: likelySubtags) {
                // One script per answer: `sr-ME` is Latin, so Apple's trailing `sr` (Cyrillic) is dropped.
                return answer.filter { sameLanguageAndScript($0, first, likelySubtags: likelySubtags) }
            }
            remaining.removeAll { $0 == first }
        }
        return []
    }

    static func preferenceList(preferences: [String], appLanguage: String, likelySubtags: Bool) -> [String] {
        preferences.filter { sameLanguageAndScript($0, appLanguage, likelySubtags: likelySubtags) } + [appLanguage]
    }

    /// The script a language tag is written in, from a fixed table: what likely subtags give, for OS versions without them.
    static func tableScript(_ identifier: String) -> String? {
        let parsed = components(identifier)
        if let script = parsed.script { return script }
        guard let language = parsed.language, let script = defaultScripts[language] else { return nil }
        if let region = parsed.region, let override = regionScripts[language]?[region] { return override }
        return script
    }

    private static let regionScripts: [String: [String: String]] = [
        "zh": ["TW": "Hant", "HK": "Hant", "MO": "Hant"],
        "yue": ["CN": "Hans"],
        "sr": ["ME": "Latn"],
        "pa": ["PK": "Aran"],
        "az": ["IR": "Arab"],
        "ku": ["IQ": "Arab", "IR": "Arab"],
        "ha": ["SD": "Arab"],
        "ms": ["CC": "Arab"],
        "kk": ["CN": "Arab"],
        "ky": ["CN": "Arab"],
        "tg": ["PK": "Arab"],
        "mn": ["CN": "Mong"],
        "uz": ["AF": "Arab", "CN": "Cyrl"],
        "sd": ["IN": "Deva"],
    ]

    private static let defaultScripts: [String: String] = {
        var table = [
            "zh": "Hans", "yue": "Hant", "sr": "Cyrl", "uz": "Latn", "pa": "Guru", "az": "Latn", "mn": "Cyrl",
            "ks": "Aran", "sd": "Arab", "ug": "Arab", "ar": "Arab", "fa": "Arab", "ur": "Arab", "ps": "Arab",
            "kk": "Cyrl", "ky": "Cyrl", "tg": "Cyrl", "ru": "Cyrl", "uk": "Cyrl", "bg": "Cyrl", "be": "Cyrl",
            "mk": "Cyrl", "he": "Hebr", "yi": "Hebr", "ja": "Jpan", "ko": "Kore", "el": "Grek", "hi": "Deva",
            "mr": "Deva", "ne": "Deva", "th": "Thai", "bn": "Beng", "ta": "Taml", "te": "Telu", "kn": "Knda",
            "ml": "Mlym", "gu": "Gujr", "si": "Sinh", "my": "Mymr", "km": "Khmr", "lo": "Laoo", "ka": "Geor",
            "hy": "Armn", "vai": "Vaii", "shi": "Tfng", "am": "Ethi", "ti": "Ethi", "bo": "Tibt",
        ]
        for language in ["en", "fr", "de", "es", "it", "pt", "nl", "sv", "nb", "da", "fi", "pl", "cs", "sk", "hu", "ro",
                         "tr", "id", "vi", "ca", "hr", "sl", "lt", "lv", "et", "bs", "ms", "ha", "fil", "sw", "af",
                         "sq", "is", "ga", "cy", "eu", "gl", "mt", "zu", "xh", "yo", "ig", "ku", "ff", "lb", "rm", "fo"] {
            table[language] = "Latn"
        }
        return table
    }()
}
