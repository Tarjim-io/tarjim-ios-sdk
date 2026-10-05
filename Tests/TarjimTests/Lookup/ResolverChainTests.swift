import Foundation
import XCTest
@testable import Tarjim

/// The lookup chain's order and formatting, case by case, and its cost.
final class ResolverChainTests: XCTestCase {
    private let egyptian = LocaleSelection(kind: .user, locales: ["ar-EG", "ar"])

    /// Fixing the app's shipped text over the air is the point: a download beats the app's own copy.
    func testDownloadedTextBeatsTheAppsOwnTextInTheSameLanguage() throws {
        let install = try LookupFixtures.install(for: self, extra: ["ns7.bundle/ar-EG.lproj/Localizable.strings": "\"app.only\" = \"من التحديث\";"])
        let resolver = LookupFixtures.resolver(app: try LookupFixtures.app(for: self), install: install, selection: egyptian)
        XCTAssertEqual(resolver.string("app.only"), "من التحديث")
    }

    /// Apple does not fall back across `.lproj` folders: the chain tries each selected locale the app ships.
    func testTheAppStepTriesEverySelectedLocaleTheAppShips() throws {
        let app = try LookupFixtures.app(for: self, extra: ["ar-EG.lproj/Localizable.strings": "\"eg.only\" = \"مصري\";"])
        let resolver = LookupFixtures.resolver(app: app, install: try LookupFixtures.install(for: self), selection: egyptian)
        XCTAssertEqual(resolver.string("eg.only"), "مصري")
        XCTAssertEqual(resolver.string("app.only"), "من التطبيق", "from the app's ar.lproj, not its English")
    }

    /// The app's own folder is found the way the locale was: `ar-EG` selected, the app ships `ar`.
    func testTheAppsFolderIsMatchedNotSpelled() throws {
        let resolver = LookupFixtures.resolver(app: try LookupFixtures.app(for: self, language: "en"), install: try LookupFixtures.install(for: self),
                                               selection: LocaleSelection(kind: .user, locales: ["ar-EG"]))
        XCTAssertEqual(resolver.string("app.only"), "من التطبيق")
    }

    /// Each string is formatted with the locale it was found in, not the first one selected.
    func testTextFoundInTheParentLocaleUsesTheParentsFormatting() throws {
        let install = try LookupFixtures.install(for: self, extra: ["ns7.bundle/ar-EG.lproj/Localizable.strings": "\"eg.count\" = \"%d متبقية\";"])
        let resolver = LookupFixtures.resolver(app: try LookupFixtures.app(for: self), install: install, selection: egyptian)
        XCTAssertEqual(resolver.string("items", arguments: [3]), "\(LookupFixtures.digits(3, "ar")) عناصر", "found in ar: ar's digits")
        XCTAssertEqual(resolver.string("eg.count", arguments: [3]), "\(LookupFixtures.digits(3, "ar-EG")) متبقية", "found in ar-EG: ar-EG's digits")
    }

    /// For a user the release has no language for, the app's own text (as Apple resolves it) comes before the
    /// fallback language's downloads — and the app's folder for the FALLBACK language is not a step at all.
    func testTheFallbackOrderIsAppThenDownloadThenKey() throws {
        let resolver = LookupFixtures.resolver(app: try LookupFixtures.app(for: self, language: "en"), install: try LookupFixtures.install(for: self),
                                               selection: LocaleSelection(kind: .fallback, locales: ["ar"]))
        XCTAssertEqual(resolver.string("app.only"), "From the app")
        XCTAssertEqual(resolver.string("app.title"), "ترجم")
    }

    /// The manifest decides what is served, not what happens to be on disk.
    func testABundleTheManifestDropsIsNotServedEvenIfOnDisk() throws {
        let entries = LookupFixtures.entries.filter { $0.id != "ns7" }
        let resolver = LookupFixtures.resolver(app: try LookupFixtures.app(for: self), install: try LookupFixtures.install(for: self),
                                               selection: LocaleSelection(kind: .user, locales: ["ar"]), entries: entries)
        XCTAssertEqual(resolver.string("app.title"), "app.title")
        XCTAssertEqual(resolver.string("app.title", bundle: .custom("checkout-screen")), "الدفع")
    }

    /// Lookups run on the main thread for every label: no file-system work per call.
    func testTenThousandLookupsInALargeAppAreFast() throws {
        let resolver = LookupFixtures.resolver(app: try LookupFixtures.largeApp(for: self), install: try LookupFixtures.install(for: self),
                                               selection: egyptian)
        let started = Date()
        for index in 0..<5_000 {
            _ = resolver.string("app.title")
            _ = resolver.string(index % 2 == 0 ? "app.only" : "no.such.key")
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 1.0)
    }
}

final class LocaleRulesTests: XCTestCase {
    /// Apple's first answer can be in the wrong script while a right one is listed: ask again without it.
    func testARejectedAnswerIsRetriedWithoutIt() {
        XCTAssertEqual(LocaleSelector.match(preference: "sr-ME", available: ["sr", "sr-Latn"]), ["sr-Latn"])
        XCTAssertEqual(LocaleSelector.match(preference: "mo", available: ["ro", "en"]), ["ro"])
    }

    /// Apple can list candidates in another script after an accepted first answer (`sr-ME`, then Cyrillic `sr`); a
    /// screen must never mix scripts, so only answers in the first one's language and script are kept.
    func testOnlyAnswersInTheAcceptedScriptAreKept() {
        XCTAssertEqual(LocaleSelector.match(preference: "sr-ME", available: ["sr-ME", "sr", "sr-Latn"]), ["sr-ME"])
        XCTAssertEqual(LocaleSelector.match(preference: "zh-HK", available: ["zh-Hant-HK", "zh-Hant", "zh"]), ["zh-Hant-HK", "zh-Hant"])
    }

    /// Manifest keys become folder names; one that is not a plain locale tag is never selected.
    func testAKeyThatIsNotALocaleTagIsNeverSelected() {
        XCTAssertEqual(LocaleSelector.match(preference: "en", available: ["../en", "en/x"]), [])
        XCTAssertEqual(LocaleSelector.select(available: ["../x", "en"], preferences: ["en-US"], appLanguage: "en", override: "../x",
                                             fallbackLanguage: "en"), LocaleSelection(kind: .user, locales: ["en"]))
    }

    /// iOS 15 has no likely-subtags lookup; the table that stands in for it must agree with Apple's on every language
    /// written in more than one script, and on the plain ones it is asked about.
    func testTheScriptTableAgreesWithApple() {
        // Apple's answer exists only from iOS 16; on iOS 15 there is nothing to compare the table with. Cases whose
        // likely script changed between Apple's data versions (ku-IQ, sd-IN) are left out: no single answer is right.
        guard #available(iOS 16, macOS 13, *) else { return }
        let corpus = ["zh", "zh-CN", "zh-TW", "zh-HK", "zh-MO", "zh-SG", "zh-Hant", "zh-Hans-HK", "yue", "yue-CN", "sr", "sr-RS", "sr-ME",
                      "sr-Latn", "sr-Cyrl-ME", "uz", "uz-AF", "pa", "pa-PK", "az", "az-IR", "mn", "bs", "ms", "ha", "ks", "sd", "ug",
                      "kk", "ky", "tg", "ar", "en", "en-GB", "ru", "he", "iw", "ja", "ko", "el", "hi", "th", "fil", "tl", "no", "nb", "mo",
                      "ku", "ff", "lb", "rm", "fo", "vai", "shi", "ha-SD", "ms-CC", "kk-CN", "ky-CN", "tg-PK", "mn-CN",
                      "uz-CN", "pa-IN", "az-AZ", "zh-Hant-CN", "sr-Latn-RS", "bs-Cyrl"]
        for identifier in corpus {
            let canonical = Locale.canonicalLanguageIdentifier(from: identifier)
            let apple = Locale.Language(identifier: Locale.Language(identifier: canonical).maximalIdentifier).script?.identifier
            XCTAssertEqual(LocaleSelector.tableScript(identifier), apple, identifier)
        }
    }

    /// The iOS 15 path, forced here: scripts are kept apart even when neither side names one.
    func testWithoutLikelySubtagsScriptsAreStillKeptApart() {
        XCTAssertEqual(LocaleSelector.match(preference: "zh-Hant-TW", available: ["zh-CN", "en"], likelySubtags: false), [])
        XCTAssertEqual(LocaleSelector.match(preference: "zh-HK", available: ["zh-Hans", "en"], likelySubtags: false), [])
        XCTAssertEqual(LocaleSelector.match(preference: "sr-Latn-RS", available: ["sr", "en"], likelySubtags: false), [])
        XCTAssertEqual(LocaleSelector.match(preference: "zh-TW", available: ["zh-Hant", "zh-Hans"], likelySubtags: false), ["zh-Hant"])
        XCTAssertEqual(LocaleSelector.match(preference: "he-IL", available: ["iw", "en"], likelySubtags: false), ["iw"])
        XCTAssertEqual(LocaleSelector.match(preference: "ar-EG", available: ["ar-EG", "ar", "en"], likelySubtags: false), ["ar-EG", "ar"])
        XCTAssertEqual(LocaleSelector.preferenceList(preferences: ["zh-TW", "zh-Hans-CN"], appLanguage: "zh-Hans", likelySubtags: false),
                       ["zh-Hans-CN", "zh-Hans"])
    }

    /// The comparator is a total order: the same entries in any order give the same bundle.
    func testTheBundleOrderIsTotal() {
        let ids = ["z1", "a2", "m"]
        var answers = Set<String>()
        for permutation in [[0, 1, 2], [0, 2, 1], [1, 0, 2], [1, 2, 0], [2, 0, 1], [2, 1, 0]] {
            let entries = permutation.map { ManifestBundle(id: ids[$0], type: "namespace", name: "x") }
            answers.insert(BundleDirectory.id(for: .namespace("x"), in: entries) ?? "nil")
        }
        XCTAssertEqual(answers, ["z1"])
    }
}

final class ResolverConcurrencyTests: XCTestCase {
    /// First lookups fill the app-folder cache from many threads at once (run under the thread sanitizer in CI).
    func testConcurrentFirstLookupsAgree() throws {
        let resolver = LookupFixtures.resolver(app: try LookupFixtures.app(for: self), install: try LookupFixtures.install(for: self),
                                               selection: LocaleSelection(kind: .user, locales: ["ar-EG", "ar"]))
        let answers = Counter()
        DispatchQueue.concurrentPerform(iterations: 400) { index in
            let value = resolver.string(index % 2 == 0 ? "app.only" : "app.title")
            if value == "من التطبيق" || value == "ترجم" { answers.increment() }
        }
        XCTAssertEqual(answers.value, 400)
    }
}
