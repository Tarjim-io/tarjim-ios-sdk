import Foundation
import XCTest
@testable import Tarjim

/// Another library's class swap made AFTER ours.
final class LaterSwapBundle: Bundle, @unchecked Sendable {
    override func localizedString(forKey key: String, value: String?, table tableName: String?) -> String {
        key == "later.only" ? "From the later library" : super.localizedString(forKey: key, value: value, table: tableName)
    }
}

/// An earlier patch counting the attributed lookup, which Swift does not expose to override.
final class AttributedCountingBundle: Bundle, @unchecked Sendable {
    nonisolated(unsafe) static var lookups = 0
    private static let lock = NSLock()
    static func reset() { lock.withLock { lookups = 0 } }
    static var count: Int { lock.withLock { lookups } }

    override func __localizedAttributedString(forKey key: String, value: String?, table tableName: String?) -> NSAttributedString {
        Self.lock.withLock { Self.lookups += 1 }
        return super.__localizedAttributedString(forKey: key, value: value, table: tableName)
    }
}

/// The proxy's edges: the same answers as `Tarjim.string`, Apple's formatting kept, other patches respected.
final class MainBundleProxyEdgeTests: XCTestCase {
    private func patched(_ selection: LocaleSelection, extra: [String: String] = [:],
                         asked: TestValue<Int>? = nil) throws -> (Bundle, Resolver) {
        let bundle = try LookupFixtures.appBundle(for: self)
        let resolver = LookupFixtures.resolver(app: AppResources(bundle: bundle, language: "en"),
                                               install: try LookupFixtures.install(for: self, extra: extra), selection: selection)
        XCTAssertTrue(MainBundleProxy.install(on: bundle) { key, table in
            asked?.value += 1
            return resolver.downloaded(key, table: table)
        })
        return (bundle, resolver)
    }

    private func attributed(_ bundle: Bundle, _ key: String) -> NSAttributedString {
        typealias Lookup = @convention(c) (AnyObject, Selector, NSString, NSString?, NSString?) -> NSAttributedString
        let selector = NSSelectorFromString("localizedAttributedStringForKey:value:table:")
        return unsafeBitCast(bundle.method(for: selector), to: Lookup.self)(bundle, selector, key as NSString, nil, nil)
    }

    /// A user on the fallback language: the app's own text first, then the downloaded fallback — as `Tarjim.string` does.
    func testAFallbackUserGetsTheAppsOwnTextFirst() throws {
        let (bundle, resolver) = try patched(LocaleSelection(kind: .fallback, locales: ["ar"]))
        XCTAssertEqual(bundle.localizedString(forKey: "greeting", value: nil, table: nil), "App hello, %@!")
        XCTAssertEqual(bundle.localizedString(forKey: "greeting", value: nil, table: nil), resolver.string("greeting"))
        XCTAssertEqual(bundle.localizedString(forKey: "app.title", value: nil, table: nil), "ترجم")
        XCTAssertEqual(bundle.localizedString(forKey: "nowhere", value: "v", table: nil), "v")
    }

    func testEverySelectedLocaleIsReadInOrder() throws {
        let (bundle, _) = try patched(LocaleSelection(kind: .user, locales: ["ar-EG", "ar"]),
                                      extra: ["ns7.bundle/ar-EG.lproj/Localizable.strings": "\"greeting\" = \"أهلاً يا %@\";"])
        XCTAssertEqual(bundle.localizedString(forKey: "greeting", value: nil, table: nil), "أهلاً يا %@")
        XCTAssertEqual(bundle.localizedString(forKey: "app.title", value: nil, table: nil), "ترجم")
    }

    /// `Tarjim.string` with the proxy on never goes back through the proxy; a proxied miss asks the download once.
    func testTheDownloadIsAskedOncePerLookupAndNeverByTheResolver() throws {
        let asked = TestValue(0)
        let (bundle, resolver) = try patched(LocaleSelection(kind: .user, locales: ["en"]), asked: asked)
        _ = resolver.string("app.only")
        _ = resolver.string("nowhere")
        XCTAssertEqual(asked.value, 0)
        _ = bundle.localizedString(forKey: "app.only", value: nil, table: nil)
        XCTAssertEqual(asked.value, 1)
    }

    /// SwiftUI's lookup keeps what Apple attaches: plural rules for a `.stringsdict` key, and parsed markdown.
    func testTheAttributedLookupKeepsApplesFormatting() throws {
        let (bundle, _) = try patched(LocaleSelection(kind: .user, locales: ["en"]),
                                      extra: ["ns7.bundle/en.lproj/Localizable.strings": "\"md\" = \"**New** text\";\n\"app.title\" = \"Tarjim\";"])
        XCTAssertEqual(attributed(bundle, "md").string, "New text")
        let install = try XCTUnwrap(LookupFixtures.install(for: self))
        let lproj = try XCTUnwrap(Bundle(url: install.appendingPathComponent("ns7.bundle/en.lproj")))
        let expected = attributed(lproj, "items")
        let served = attributed(bundle, "items")
        XCTAssertEqual(served.string, expected.string)
        XCTAssertEqual(Set(served.attributes(at: 0, effectiveRange: nil).keys), Set(expected.attributes(at: 0, effectiveRange: nil).keys))
    }

    /// A bundle already observed (KVO) is left alone: its real class differs from the one it reports.
    func testABundleUnderKeyValueObservationIsNotPatched() throws {
        let bundle = try LookupFixtures.appBundle(for: self)
        final class Observer: NSObject {}
        let observer = Observer()
        bundle.addObserver(observer, forKeyPath: "bundlePath", options: [], context: nil)
        let resolver = LookupFixtures.resolver(app: AppResources(bundle: bundle, language: "en"),
                                               install: try LookupFixtures.install(for: self), selection: LocaleSelection(kind: .user, locales: ["en"]))
        XCTAssertFalse(MainBundleProxy.install(on: bundle) { key, table in resolver.downloaded(key, table: table) })
        XCTAssertFalse(MainBundleProxy.isInstalled(on: bundle))
        XCTAssertEqual(bundle.localizedString(forKey: "app.only", value: nil, table: nil), "From the app")
        bundle.removeObserver(observer, forKeyPath: "bundlePath")
        XCTAssertEqual(bundle.localizedString(forKey: "app.only", value: nil, table: nil), "From the app")
    }

    /// Another library swapping the class after ours wins; the proxy then reports itself as no longer installed.
    func testALaterClassSwapIsRespected() throws {
        let (bundle, resolver) = try patched(LocaleSelection(kind: .user, locales: ["en"]))
        object_setClass(bundle, LaterSwapBundle.self)
        XCTAssertFalse(MainBundleProxy.isInstalled(on: bundle))
        XCTAssertEqual(resolver.string("later.only"), "From the later library")
    }

    /// A global method exchange on NSBundle made after install is still reached on a miss.
    func testAGlobalExchangeAfterInstallIsReachedOnAMiss() throws {
        let (bundle, _) = try patched(LocaleSelection(kind: .user, locales: ["en"]))
        let selector = NSSelectorFromString("localizedStringForKey:value:table:")
        let method = try XCTUnwrap(class_getInstanceMethod(Bundle.self, selector))
        let before = method_getImplementation(method)
        typealias Lookup = @convention(c) (AnyObject, Selector, NSString, NSString?, NSString?) -> NSString
        let original = unsafeBitCast(before, to: Lookup.self)
        let block: @convention(block) (AnyObject, NSString, NSString?, NSString?) -> NSString = { object, key, value, table in
            (key as String) == "swizzled.only" ? "From the swizzler" : original(object, selector, key, value, table)
        }
        method_setImplementation(method, imp_implementationWithBlock(block))
        defer { method_setImplementation(method, before) }
        XCTAssertEqual(bundle.localizedString(forKey: "swizzled.only", value: nil, table: nil), "From the swizzler")
        XCTAssertEqual(bundle.localizedString(forKey: "app.title", value: nil, table: nil), "Tarjim")
    }

    /// For a fallback user too, a key missing everywhere reaches the app's own lookup exactly once.
    func testAFallbackMissAsksTheAppOnce() throws {
        let bundle = try LookupFixtures.appBundle(for: self)
        object_setClass(bundle, CountingBundle.self)
        CountingBundle.reset()
        let resolver = LookupFixtures.resolver(app: AppResources(bundle: bundle, language: "en"), install: try LookupFixtures.install(for: self),
                                               selection: LocaleSelection(kind: .fallback, locales: ["ar"]))
        XCTAssertTrue(MainBundleProxy.install(on: bundle) { key, table in resolver.downloaded(key, table: table) })
        XCTAssertEqual(bundle.localizedString(forKey: "nowhere", value: "v", table: nil), "v")
        XCTAssertEqual(CountingBundle.count, 1)
        XCTAssertEqual(bundle.localizedString(forKey: "nowhere", value: nil, table: nil), "nowhere")
        XCTAssertEqual(CountingBundle.count, 2)
    }

    /// The attributed lookup of a fallback user reaches the app's own lookup exactly once, hit or miss.
    func testAFallbackAttributedLookupAsksTheAppOnce() throws {
        let bundle = try LookupFixtures.appBundle(for: self)
        object_setClass(bundle, AttributedCountingBundle.self)
        AttributedCountingBundle.reset()
        let resolver = LookupFixtures.resolver(app: AppResources(bundle: bundle, language: "en"), install: try LookupFixtures.install(for: self),
                                               selection: LocaleSelection(kind: .fallback, locales: ["ar"]))
        XCTAssertTrue(MainBundleProxy.install(on: bundle) { key, table in resolver.downloaded(key, table: table) })
        XCTAssertEqual(attributed(bundle, "app.only").string, "From the app")
        XCTAssertEqual(AttributedCountingBundle.count, 1)
        XCTAssertEqual(attributed(bundle, "nowhere").string, "nowhere")
        XCTAssertEqual(AttributedCountingBundle.count, 2)
        XCTAssertEqual(attributed(bundle, "app.title").string, "ترجم")
        XCTAssertEqual(AttributedCountingBundle.count, 3)
    }
}
