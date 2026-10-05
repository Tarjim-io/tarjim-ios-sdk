import Foundation
import XCTest
@testable import Tarjim

/// Another library's earlier patch of the same bundle: it must keep working under ours, and be asked once per miss.
final class CountingBundle: Bundle, @unchecked Sendable {
    nonisolated(unsafe) static var lookups = 0
    private static let lock = NSLock()

    static func reset() { lock.withLock { lookups = 0 } }
    static var count: Int { lock.withLock { lookups } }

    override func localizedString(forKey key: String, value: String?, table tableName: String?) -> String {
        Self.lock.withLock { Self.lookups += 1 }
        return super.localizedString(forKey: key, value: value, table: tableName)
    }
}

final class MainBundleProxyTests: XCTestCase {
    private let english = LocaleSelection(kind: .user, locales: ["en"])

    /// A fixture app bundle patched by the proxy, with Tarjim's downloaded English release behind it.
    private func patchedApp(otherPatchFirst: Bool = false) throws -> (Bundle, Resolver) {
        let bundle = try LookupFixtures.appBundle(for: self)
        if otherPatchFirst {
            object_setClass(bundle, CountingBundle.self)
            CountingBundle.reset()
        }
        let resolver = LookupFixtures.resolver(app: AppResources(bundle: bundle, language: "en"),
                                               install: try LookupFixtures.install(for: self, locales: ["en"]), selection: english)
        XCTAssertTrue(MainBundleProxy.install(on: bundle) { key, table in resolver.downloaded(key, table: table) })
        return (bundle, resolver)
    }

    func testTheBundlesOwnLookupServesDownloadedText() throws {
        let (bundle, _) = try patchedApp()
        XCTAssertEqual(bundle.localizedString(forKey: "app.title", value: nil, table: nil), "Tarjim")
        XCTAssertEqual(bundle.localizedString(forKey: "app.title", value: nil, table: "Localizable"), "Tarjim")
        XCTAssertEqual(NSLocalizedString("app.title", bundle: bundle, comment: ""), "Tarjim")
    }

    /// Text the download lacks comes from the app's own resources, with Apple's `value` semantics intact.
    func testAMissIsTheAppsOwnText() throws {
        let (bundle, _) = try patchedApp()
        XCTAssertEqual(bundle.localizedString(forKey: "app.only", value: nil, table: nil), "From the app")
        XCTAssertEqual(bundle.localizedString(forKey: "nowhere", value: "Fallback", table: nil), "Fallback")
        XCTAssertEqual(bundle.localizedString(forKey: "nowhere", value: nil, table: nil), "nowhere")
    }

    /// A table names a Tarjim bundle: a namespace of that name, else a custom bundle of that name (a storyboard's table).
    func testTablesNameTarjimBundles() throws {
        let (bundle, _) = try patchedApp()
        XCTAssertEqual(bundle.localizedString(forKey: "app.title", value: nil, table: "checkout"), "Checkout")
        XCTAssertEqual(bundle.localizedString(forKey: "pay.button", value: nil, table: "checkout-screen"), "Pay %@")
        XCTAssertEqual(bundle.localizedString(forKey: "app.only", value: nil, table: "checkout"), "From the checkout table",
                       "a miss reads the app's own table of that name")
    }

    /// An earlier patch by another library still answers, and is asked exactly once per miss — never for a hit.
    func testAnEarlierPatchIsKeptAndAskedOncePerMiss() throws {
        let (bundle, _) = try patchedApp(otherPatchFirst: true)
        XCTAssertEqual(bundle.localizedString(forKey: "app.title", value: nil, table: nil), "Tarjim")
        XCTAssertEqual(CountingBundle.count, 0)
        XCTAssertEqual(bundle.localizedString(forKey: "app.only", value: nil, table: nil), "From the app")
        XCTAssertEqual(CountingBundle.count, 1)
    }

    /// `Tarjim.string` with the proxy on reaches the app's own text once, without going round through the proxy again.
    func testTheResolverDoesNotRecurseThroughThePatch() throws {
        let (_, resolver) = try patchedApp(otherPatchFirst: true)
        XCTAssertEqual(resolver.string("app.only"), "From the app")
        XCTAssertEqual(CountingBundle.count, 1)
        XCTAssertEqual(resolver.string("nowhere"), "nowhere")
        XCTAssertEqual(CountingBundle.count, 2)
    }

    func testInstallingTwiceChangesNothing() throws {
        let (bundle, resolver) = try patchedApp()
        let patched: AnyClass? = object_getClass(bundle)
        XCTAssertFalse(MainBundleProxy.install(on: bundle) { key, table in resolver.downloaded(key, table: table) })
        XCTAssertTrue(object_getClass(bundle) === patched)
        XCTAssertTrue(MainBundleProxy.isInstalled(on: bundle))
        XCTAssertEqual(bundle.localizedString(forKey: "app.only", value: nil, table: nil), "From the app")
    }

    /// The lookup SwiftUI's `Text("key")` uses in the default environment.
    func testTheAttributedLookupServesDownloadedText() throws {
        let (bundle, _) = try patchedApp()
        XCTAssertEqual(attributed(bundle, "app.title"), "Tarjim")
        XCTAssertEqual(attributed(bundle, "app.only"), "From the app")
    }

    func testTheOriginalLookupIsTheAppsOwn() throws {
        let (bundle, _) = try patchedApp()
        XCTAssertEqual(MainBundleProxy.original(bundle, key: "app.title", value: nil, table: nil), "app.title")
        XCTAssertEqual(MainBundleProxy.original(bundle, key: "app.only", value: nil, table: nil), "From the app")
    }
}

/// `-[NSBundle localizedAttributedStringForKey:value:table:]`, which Swift does not expose; SwiftUI calls it.
private func attributed(_ bundle: Bundle, _ key: String) -> String {
    typealias Lookup = @convention(c) (AnyObject, Selector, NSString, NSString?, NSString?) -> NSAttributedString
    let selector = NSSelectorFromString("localizedAttributedStringForKey:value:table:")
    let lookup = unsafeBitCast(bundle.method(for: selector), to: Lookup.self)
    return lookup(bundle, selector, key as NSString, nil, nil).string
}

final class RuntimeProxyTests: XCTestCase {
    func testTheRuntimeInstallsTheProxyUnlessTurnedOff() async throws {
        for intercepts in [true, false] {
            let harness = try RuntimeHarness(self)
            harness.server.publish(try Release.one())
            var configuration = harness.configuration()
            configuration.interceptsMainBundle = intercepts
            let runtime = try harness.make(configuration)
            await runtime.start(foreground: true)
            await runtime.checkNow()
            XCTAssertEqual(MainBundleProxy.isInstalled(on: harness.appBundle), intercepts)
            let title = harness.appBundle.localizedString(forKey: "app.title", value: nil, table: nil)
            XCTAssertEqual(title, intercepts ? "Tarjim" : "app.title")
        }
    }
}
