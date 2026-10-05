import XCTest
@testable import Tarjim

/// Expected answers are Apple's matcher as measured on macOS 15 and iOS 16.4/26.5; the acceptance check is ours.
final class LocaleSelectorTests: XCTestCase {
    func testAMatchKeepsApplesOrder() {
        XCTAssertEqual(LocaleSelector.match(preference: "ar-EG", available: ["ar-EG", "ar", "en"]), ["ar-EG", "ar"])
        XCTAssertEqual(LocaleSelector.match(preference: "es-MX", available: ["es", "es-419", "es-MX"]), ["es-MX", "es-419", "es"])
    }

    /// Apple's matcher answers even when nothing matches (`de-DE` → `en`); that answer is not a match.
    func testANoMatchIsNotServed() {
        XCTAssertEqual(LocaleSelector.match(preference: "de-DE", available: ["en", "ar"]), [])
        XCTAssertEqual(LocaleSelector.match(preference: "pt-PT", available: ["en", "ar"]), [])
        XCTAssertEqual(LocaleSelector.match(preference: "de-DE", available: ["en", "de"]), ["de"])
    }

    func testLegacyAndAliasCodesMatch() {
        XCTAssertEqual(LocaleSelector.match(preference: "he-IL", available: ["iw", "en"]), ["iw"])
        XCTAssertEqual(LocaleSelector.match(preference: "nb-NO", available: ["nb", "no", "en"]), ["nb", "no"])
        XCTAssertEqual(LocaleSelector.match(preference: "nb-NO", available: ["no", "en"]), ["no"])
        XCTAssertEqual(LocaleSelector.match(preference: "fil", available: ["tl", "en"]), ["tl"])
        XCTAssertEqual(LocaleSelector.match(preference: "id", available: ["in", "en"]), ["in"])
        XCTAssertEqual(LocaleSelector.match(preference: "pt-PT", available: ["pt-BR", "en"]), ["pt-BR"])
    }

    /// Text in another script is another language to its reader.
    func testTheScriptMustAgree() {
        XCTAssertEqual(LocaleSelector.match(preference: "sr-Latn", available: ["sr", "en"]), [], "sr is Cyrillic")
        XCTAssertEqual(LocaleSelector.match(preference: "sr-Latn-RS", available: ["sr", "sr-Latn"]), ["sr-Latn"])
        XCTAssertEqual(LocaleSelector.match(preference: "zh-Hant-HK", available: ["zh-Hant-TW", "en"]), ["zh-Hant-TW"])
        XCTAssertEqual(LocaleSelector.match(preference: "zh-Hant", available: ["zh-Hans", "en"]), [])
        XCTAssertEqual(LocaleSelector.match(preference: "zh-TW", available: ["zh-Hans", "en"]), [], "zh-TW is Traditional")
        XCTAssertEqual(LocaleSelector.match(preference: "zh-TW", available: ["zh-Hant", "zh-Hans"]), ["zh-Hant"])
    }

    /// Only a key the manifest lists is ever requested, spelled as the manifest spells it.
    func testTheAnswerIsTheManifestsKeysVerbatim() {
        XCTAssertEqual(LocaleSelector.match(preference: "en-GB", available: ["EN", "AR"]), ["EN"])
        XCTAssertEqual(LocaleSelector.match(preference: "ar_EG", available: ["ar"]), ["ar"])
        XCTAssertEqual(LocaleSelector.match(preference: "ar", available: []), [])
    }

    /// The device's languages narrowed to the app's language and script, then the app's language.
    func testThePreferenceListFollowsTheAppsLanguage() {
        let device = ["fr-FR", "ar-EG", "en-US", "ar-LB"]
        XCTAssertEqual(LocaleSelector.preferenceList(preferences: device, appLanguage: "ar"), ["ar-EG", "ar-LB", "ar"])
        XCTAssertEqual(LocaleSelector.preferenceList(preferences: device, appLanguage: "en"), ["en-US", "en"])
        XCTAssertEqual(LocaleSelector.preferenceList(preferences: [], appLanguage: "en"), ["en"])
        XCTAssertEqual(LocaleSelector.preferenceList(preferences: ["zh-Hant-TW", "zh-Hans-CN"], appLanguage: "zh-Hans"), ["zh-Hans-CN", "zh-Hans"])
        XCTAssertEqual(LocaleSelector.preferenceList(preferences: ["iw-IL"], appLanguage: "he"), ["iw-IL", "he"])
    }

    func testTheUsersRegionIsKeptInsideTheAppsLanguage() {
        let selection = LocaleSelector.select(available: ["en", "ar", "ar-EG"], preferences: ["ar-EG", "en-US"], appLanguage: "ar",
                                              override: nil, fallbackLanguage: "en")
        XCTAssertEqual(selection, LocaleSelection(kind: .user, locales: ["ar-EG", "ar"]))
    }

    /// A user whose second device language is in the release still gets the app's language (D-1).
    func testAnotherDeviceLanguageIsNotServed() {
        let selection = LocaleSelector.select(available: ["ar", "fr"], preferences: ["fr-FR", "de-DE"], appLanguage: "de",
                                              override: nil, fallbackLanguage: "ar")
        XCTAssertEqual(selection, LocaleSelection(kind: .fallback, locales: ["ar"]))
    }

    func testTraditionalChineseIsNotServedInASimplifiedApp() {
        let selection = LocaleSelector.select(available: ["zh-Hant-TW", "en"], preferences: ["zh-Hant-TW"], appLanguage: "zh-Hans",
                                              override: nil, fallbackLanguage: "en")
        XCTAssertEqual(selection, LocaleSelection(kind: .fallback, locales: ["en"]))
    }

    /// The fallback language is for a whole user whose language the release lacks, never in addition.
    func testTheFallbackLanguageIsUsedOnlyWhenTheUsersIsMissing() {
        XCTAssertEqual(LocaleSelector.select(available: ["ar", "en"], preferences: ["ar-LB"], appLanguage: "ar", override: nil, fallbackLanguage: "en"),
                       LocaleSelection(kind: .user, locales: ["ar"]))
        XCTAssertEqual(LocaleSelector.select(available: ["en", "ar"], preferences: ["de-DE"], appLanguage: "de", override: nil, fallbackLanguage: "en"),
                       LocaleSelection(kind: .fallback, locales: ["en"]))
        XCTAssertNil(LocaleSelector.select(available: ["en", "ar"], preferences: ["de-DE"], appLanguage: "de", override: nil, fallbackLanguage: "fr"),
                     "a fallback the release lacks selects nothing: the app's own text")
    }

    /// An override the manifest lists replaces the preference list; one it does not list is ignored.
    func testAnOverrideIsUsedOnlyWhenTheManifestListsIt() {
        XCTAssertEqual(LocaleSelector.select(available: ["en", "ar"], preferences: ["en-US"], appLanguage: "en", override: "ar", fallbackLanguage: "en"),
                       LocaleSelection(kind: .user, locales: ["ar"]))
        XCTAssertEqual(LocaleSelector.select(available: ["en", "ar"], preferences: ["en-US"], appLanguage: "en", override: "AR", fallbackLanguage: "en"),
                       LocaleSelection(kind: .user, locales: ["ar"]))
        XCTAssertEqual(LocaleSelector.select(available: ["en", "ar"], preferences: ["en-US"], appLanguage: "en", override: "fr", fallbackLanguage: "en"),
                       LocaleSelection(kind: .user, locales: ["en"]))
    }
}
