import Foundation
import XCTest
@testable import Tarjim

final class ResolverTests: XCTestCase {
    private let arabic = LocaleSelection(kind: .user, locales: ["ar"])

    /// Apple's formatter wraps an argument whose direction differs from the text in U+2068…U+2069 when it is
    /// given a locale; the SDK passes that through untouched, as `String(localized:)` would.
    private func isolated(_ text: String) -> String {
        String(UnicodeScalar(0x2068)!) + text + String(UnicodeScalar(0x2069)!)
    }

    func testADownloadedStringIsServed() throws {
        let resolver = LookupFixtures.resolver(app: try LookupFixtures.app(for: self), install: try LookupFixtures.install(for: self), selection: arabic)
        XCTAssertEqual(resolver.string("app.title"), "ترجم")
        XCTAssertEqual(resolver.string("app.title", bundle: .custom("checkout-screen")), "الدفع")
        XCTAssertEqual(resolver.string("greeting", arguments: ["Sam"]), "مرحبًا، \(isolated("Sam"))!")
    }

    /// The selected locales are read in order; a key missing in the regional file comes from the parent.
    func testTheSelectedLocalesAreReadInOrder() throws {
        let install = try LookupFixtures.install(for: self, extra: ["ns7.bundle/ar-EG.lproj/Localizable.strings": "\"greeting\" = \"أهلاً يا %@\";"])
        let resolver = LookupFixtures.resolver(app: try LookupFixtures.app(for: self), install: install,
                                               selection: LocaleSelection(kind: .user, locales: ["ar-EG", "ar"]))
        XCTAssertEqual(resolver.string("greeting", arguments: ["Sam"]), "أهلاً يا \(isolated("Sam"))")
        XCTAssertEqual(resolver.string("app.title"), "ترجم")
    }

    /// A key the download lacks comes from the app's own copy in the selected language, then as Apple resolves it.
    func testAMissComesFromTheAppsOwnText() throws {
        let app = try LookupFixtures.app(for: self)
        let install = try LookupFixtures.install(for: self, locales: ["ar"],
                                                 extra: ["ns7.bundle/de.lproj/Localizable.strings": "\"app.title\" = \"Tarjim DE\";"])
        XCTAssertEqual(LookupFixtures.resolver(app: app, install: install, selection: arabic).string("app.only"), "من التطبيق",
                       "the app's ar.lproj")
        let german = LookupFixtures.resolver(app: app, install: install, selection: LocaleSelection(kind: .user, locales: ["de"]))
        XCTAssertEqual(german.string("app.title"), "Tarjim DE")
        XCTAssertEqual(german.string("app.only"), "From the app", "the app ships no de.lproj: its own language")
    }

    func testAKeyNobodyHasIsItsOwnNameNeverEmpty() throws {
        let resolver = LookupFixtures.resolver(app: try LookupFixtures.app(for: self), install: try LookupFixtures.install(for: self), selection: arabic)
        XCTAssertEqual(resolver.string("no.such.key"), "no.such.key")
        XCTAssertEqual(resolver.string("no.such.key", arguments: [3]), "no.such.key")
    }

    /// The app's own copy of a bundle is the table of the bundle's name, or `Localizable` when the app has none.
    func testTheAppsTableIsNamedAfterTheBundle() throws {
        let resolver = LookupFixtures.resolver(app: try LookupFixtures.app(for: self), install: try LookupFixtures.install(for: self, locales: ["en"]),
                                               selection: LocaleSelection(kind: .user, locales: ["en"]))
        XCTAssertEqual(resolver.string("app.only", bundle: .namespace("checkout")), "From the checkout table")
        XCTAssertEqual(resolver.string("app.only", bundle: .namespace("default")), "From the app")
        XCTAssertEqual(resolver.string("app.only", bundle: .namespace("not-in-the-release")), "From the app")
    }

    /// No `bundle:` argument means the configured default, however many bundles the release gains.
    func testTheDefaultBundleNeverChangesMeaning() throws {
        let install = try LookupFixtures.install(for: self, extra: ["b9.bundle/ar.lproj/Localizable.strings": "\"app.title\" = \"مخصص\";"])
        let app = try LookupFixtures.app(for: self)
        let grown = LookupFixtures.entries + [ManifestBundle(id: "b9", type: "custom", name: "default"), ManifestBundle(id: "ns2", type: "namespace", name: "zz")]
        let resolver = LookupFixtures.resolver(app: app, install: install, selection: arabic, entries: grown)
        XCTAssertEqual(resolver.string("app.title"), "ترجم")
        XCTAssertEqual(resolver.string("app.title", bundle: .custom("default")), "مخصص")
        let custom = LookupFixtures.resolver(app: app, install: install, selection: arabic, entries: grown, defaultBundle: .custom("checkout-screen"))
        XCTAssertEqual(custom.string("app.title"), "الدفع")
    }

    /// The plural category follows the locale of the text, not the app's language.
    func testADownloadedArabicPluralUsesArabicRules() throws {
        let resolver = LookupFixtures.resolver(app: try LookupFixtures.app(for: self, language: "en"), install: try LookupFixtures.install(for: self),
                                               selection: arabic)
        XCTAssertEqual(resolver.string("items", arguments: [0]), "لا عناصر")
        XCTAssertEqual(resolver.string("items", arguments: [2]), "عنصران")
        XCTAssertEqual(resolver.string("items", arguments: [3]), "3 عناصر")
        XCTAssertEqual(resolver.string("items", arguments: [11]), "11 عنصرًا")
        XCTAssertEqual(resolver.string("items", arguments: [100]), "100 عنصر")
    }

    func testTheAppsOwnArabicPluralUsesArabicRules() throws {
        let resolver = LookupFixtures.resolver(app: try LookupFixtures.app(for: self, language: "en"), install: try LookupFixtures.install(for: self),
                                               selection: arabic)
        XCTAssertEqual(resolver.string("app.items", arguments: [2]), "اثنان")
        XCTAssertEqual(resolver.string("app.items", arguments: [3]), "3 قليلة")
        XCTAssertEqual(resolver.string("app.items", arguments: [11]), "11 كثيرة")
    }

    /// Each string is formatted with the locale it was read in: Egyptian Arabic text gets Arabic-Indic digits,
    /// the app's own English text keeps Western ones (the app ships no ar-EG and its ar lacks the key).
    func testDigitsFollowTheLocaleOfTheText() throws {
        let install = try LookupFixtures.install(for: self, extra: ["ns7.bundle/ar-EG.lproj/Localizable.strings": "\"eg.count\" = \"%d متبقية\";"])
        let resolver = LookupFixtures.resolver(app: try LookupFixtures.app(for: self, language: "en"), install: install,
                                               selection: LocaleSelection(kind: .user, locales: ["ar-EG", "ar"]))
        XCTAssertEqual(resolver.string("eg.count", arguments: [3]), "٣ متبقية")
        XCTAssertEqual(resolver.string("count.only", arguments: [3]), "3 left")
    }

    /// Apple's unformatted plural, as documented.
    func testAPluralWithoutArgumentsIsApplesFormat() throws {
        let resolver = LookupFixtures.resolver(app: try LookupFixtures.app(for: self), install: try LookupFixtures.install(for: self), selection: arabic)
        XCTAssertEqual(resolver.string("items"), "%#@v@")
    }

    /// The device has what the release lists: a dropped locale or bundle falls to the app's own text.
    func testWhatTheInstallNoLongerHoldsIsNotServed() throws {
        let app = try LookupFixtures.app(for: self)
        let install = try LookupFixtures.install(for: self, bundles: ["ns12"], locales: ["ar"])
        let resolver = LookupFixtures.resolver(app: app, install: install, selection: arabic,
                                               entries: [ManifestBundle(id: "ns12", type: "namespace", name: "checkout")])
        XCTAssertEqual(resolver.string("app.title"), "app.title")
        XCTAssertEqual(resolver.string("app.only"), "من التطبيق")
    }

    /// A user whose language the release lacks: the app's own text first, then the fallback language, then the key.
    func testTheFallbackLanguageComesAfterTheAppsOwnText() throws {
        let resolver = LookupFixtures.resolver(app: try LookupFixtures.app(for: self, language: "en"), install: try LookupFixtures.install(for: self),
                                               selection: LocaleSelection(kind: .fallback, locales: ["en"]))
        XCTAssertEqual(resolver.string("greeting", arguments: ["Sam"]), "App hello, Sam!")
        XCTAssertEqual(resolver.string("app.title"), "Tarjim")
        XCTAssertEqual(resolver.string("no.such.key"), "no.such.key")
    }

    /// Before `start()` there is nothing downloaded: the app's own text, never a crash or a wait.
    func testBeforeStartLookupsUseTheAppsOwnText() throws {
        let resolver = Resolver(app: try LookupFixtures.app(for: self), defaultBundle: .namespace("default"), snapshot: { .empty })
        XCTAssertEqual(resolver.string("app.only"), "From the app")
        XCTAssertEqual(resolver.string("greeting", arguments: ["Sam"]), "App hello, Sam!")
        XCTAssertEqual(resolver.string("app.title"), "app.title")
    }

    /// One lookup reads one snapshot, so an activation in between can never mix two installs.
    func testALookupReadsTheSnapshotOnce() throws {
        let app = try LookupFixtures.app(for: self)
        let snapshot = Snapshot(installDirectory: try LookupFixtures.install(for: self), entries: LookupFixtures.entries, selection: arabic)
        let reads = Counter()
        let resolver = Resolver(app: app, defaultBundle: .namespace("default"), snapshot: { reads.increment(); return snapshot })
        _ = resolver.string("app.title")
        _ = resolver.string("app.only")
        _ = resolver.string("no.such.key", bundle: .custom("checkout-screen"))
        _ = resolver.string("items", arguments: [3])
        XCTAssertEqual(reads.value, 4)
    }
}

final class SnapshotHolderTests: XCTestCase {
    func testReplaceSwapsWhatIsRead() {
        let holder = SnapshotHolder()
        XCTAssertTrue(holder.current === Snapshot.empty)
        let next = Snapshot(installDirectory: URL(fileURLWithPath: "/nonexistent"), entries: [], selection: nil)
        holder.replace(next)
        XCTAssertTrue(holder.current === next)
    }

    func testConcurrentReadsDuringSwapsSeeAWholeSnapshot() {
        let a = Snapshot(installDirectory: URL(fileURLWithPath: "/a"), entries: [], selection: nil)
        let b = Snapshot(installDirectory: URL(fileURLWithPath: "/b"), entries: [], selection: nil)
        let holder = SnapshotHolder(a)
        let torn = Counter()
        DispatchQueue.concurrentPerform(iterations: 2000) { i in
            if i % 10 == 0 {
                holder.replace(i % 20 == 0 ? a : b)
            } else {
                let seen = holder.current
                if seen !== a && seen !== b { torn.increment() }
            }
        }
        XCTAssertEqual(torn.value, 0)
        XCTAssertTrue(holder.current === a || holder.current === b)
    }
}

final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func increment() {
        lock.withLock { count += 1 }
    }

    var value: Int {
        lock.withLock { count }
    }
}
