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
        nil
    }

    static func preferenceList(preferences: [String], appLanguage: String) -> [String] {
        []
    }

    static func match(preference: String, available: [String]) -> [String] {
        []
    }
}
