#if canImport(UIKit)
import SwiftUI
import UIKit
import XCTest
@testable import Tarjim

/// What the proxy reaches in UIKit and SwiftUI, measured in a running iOS process.
///
/// A storyboard or xib compiled from `Base.lproj` asks its bundle for each label's text with the key
/// `<objectID>.text` in the table named after the file, in the development language too, where no strings table
/// exists for it. SwiftUI's `Text("key")` and `Button("key")` in the default environment ask the main bundle's
/// attributed-string lookup. A view under an explicit `.environment(\.locale, …)` and `String(localized:)` use a
/// lookup the proxy does not replace, and show the app's own text.
final class ProxyUIKitMeasurementTests: XCTestCase {
    /// The runner's language: the one Apple picks for a bundle that has it.
    private let language = String((Locale.preferredLanguages.first ?? "en").prefix { $0 != "-" && $0 != "_" })

    override func tearDown() {
        MainBundleDownload.resolver = nil
        super.tearDown()
    }

    // MARK: Storyboards and xibs

    @MainActor func testAStoryboardInTheDevelopmentLanguageShowsDownloadedText() throws {
        let app = try appBundle(developmentLanguage: language)
        XCTAssertEqual(storyboardLabel(app), "Base title", "the development language has no table: the storyboard's own text")
        let (patched, _) = try patch(appBundle(developmentLanguage: language), download: Self.interfaceText)
        XCTAssertEqual(storyboardLabel(patched), "Downloaded storyboard title")
    }

    @MainActor func testAStoryboardInAnotherLanguageShowsDownloadedText() throws {
        let app = try appBundle(developmentLanguage: otherLanguage, tables: ["Main": "\"lbl-01-xyz.text\" = \"Translated title\";"])
        XCTAssertEqual(storyboardLabel(app), "Translated title", "Apple applies the app's own table")
        let (patched, _) = try patch(appBundle(developmentLanguage: otherLanguage, tables: ["Main": "\"lbl-01-xyz.text\" = \"Translated title\";"]),
                                     download: Self.interfaceText)
        XCTAssertEqual(storyboardLabel(patched), "Downloaded storyboard title")
    }

    @MainActor func testAStoryboardKeyTheDownloadLacksShowsTheAppsOwnTextAskingTheAppOnce() throws {
        let (development, _) = try patch(appBundle(developmentLanguage: language), download: [:], counting: true)
        XCTAssertEqual(storyboardLabel(development), "Base title")
        XCTAssertEqual(CountingBundle.count, 1)

        let (other, _) = try patch(appBundle(developmentLanguage: otherLanguage, tables: ["Main": "\"lbl-01-xyz.text\" = \"Translated title\";"]),
                                   download: [:], counting: true)
        XCTAssertEqual(storyboardLabel(other), "Translated title")
        XCTAssertEqual(CountingBundle.count, 1)
    }

    @MainActor func testAXibInTheDevelopmentLanguageShowsDownloadedText() throws {
        let app = try appBundle(developmentLanguage: language)
        XCTAssertEqual(xibLabel(app), "Base card")
        let (patched, _) = try patch(appBundle(developmentLanguage: language), download: Self.interfaceText)
        XCTAssertEqual(xibLabel(patched), "Downloaded card")
    }

    @MainActor func testAXibInAnotherLanguageShowsDownloadedText() throws {
        let app = try appBundle(developmentLanguage: otherLanguage, tables: ["Card": "\"xlb-01-xyz.text\" = \"Translated card\";"])
        XCTAssertEqual(xibLabel(app), "Translated card")
        let (patched, _) = try patch(appBundle(developmentLanguage: otherLanguage, tables: ["Card": "\"xlb-01-xyz.text\" = \"Translated card\";"]),
                                     download: Self.interfaceText)
        XCTAssertEqual(xibLabel(patched), "Downloaded card")
    }

    @MainActor func testAXibKeyTheDownloadLacksShowsTheAppsOwnTextAskingTheAppOnce() throws {
        let (development, _) = try patch(appBundle(developmentLanguage: language), download: [:], counting: true)
        XCTAssertEqual(xibLabel(development), "Base card")
        XCTAssertEqual(CountingBundle.count, 1)

        let (other, _) = try patch(appBundle(developmentLanguage: otherLanguage, tables: ["Card": "\"xlb-01-xyz.text\" = \"Translated card\";"]),
                                   download: [:], counting: true)
        XCTAssertEqual(xibLabel(other), "Translated card")
        XCTAssertEqual(CountingBundle.count, 1)
    }

    // MARK: SwiftUI

    @MainActor func testSwiftUIInTheDefaultEnvironmentShowsDownloadedText() throws {
        MainBundleDownload.resolver = try resolver(app: .main, download: ["Localizable": "\"swiftui.title\" = \"Downloaded title\";"])
        XCTAssertTrue(MainBundleDownload.installed)
        XCTAssertEqual(shown(Text("swiftui.title"), among: ["Downloaded title", "swiftui.title"]), "Downloaded title")
        XCTAssertEqual(shown(Button("swiftui.title") {}, among: ["Downloaded title", "swiftui.title"], as: { Button($0) {} }),
                       "Downloaded title")
        XCTAssertEqual(shown(Text("swiftui.nowhere"), among: ["Downloaded title", "swiftui.nowhere"]), "swiftui.nowhere",
                       "missing everywhere: the key")
    }

    @MainActor func testSwiftUIShowsTheAppsOwnTextForAKeyTheDownloadLacks() throws {
        let app = try appBundle(developmentLanguage: language, tables: ["Localizable": "\"swiftui.title\" = \"App title\";"])
        let (patched, _) = try patch(app, download: ["Localizable": "\"swiftui.other\" = \"Downloaded other\";"])
        let candidates = ["App title", "Downloaded other", "swiftui.title"]
        XCTAssertEqual(shown(Text("swiftui.title", bundle: patched), among: candidates), "App title")
        XCTAssertEqual(shown(Button { } label: { Text("swiftui.title", bundle: patched) }, among: candidates, as: { Button($0) {} }),
                       "App title")
        XCTAssertEqual(shown(Text("swiftui.other", bundle: patched), among: candidates + ["swiftui.other"]), "Downloaded other")
    }

    /// An explicit locale makes SwiftUI use a lookup that names the localization, which the proxy does not replace.
    @MainActor func testSwiftUIUnderAnExplicitLocaleShowsTheAppsOwnText() throws {
        let tables = ["Localizable": "\"swiftui.title\" = \"App title\";"]
        let (patched, _) = try patch(appBundle(developmentLanguage: language, tables: tables),
                                     download: ["Localizable": "\"swiftui.title\" = \"Downloaded title\";"])
        let candidates = ["App title", "Downloaded title"]
        XCTAssertEqual(shown(Text("swiftui.title", bundle: patched), among: candidates), "Downloaded title")
        XCTAssertEqual(shown(Text("swiftui.title", bundle: patched).environment(\.locale, Locale(identifier: language)), among: candidates),
                       "App title")
    }

    @MainActor func testStringLocalizedShowsTheAppsOwnText() throws {
        let tables = ["Localizable": "\"swiftui.title\" = \"App title\";"]
        let (patched, _) = try patch(appBundle(developmentLanguage: language, tables: tables),
                                     download: ["Localizable": "\"swiftui.title\" = \"Downloaded title\";"])
        XCTAssertEqual(patched.localizedString(forKey: "swiftui.title", value: nil, table: nil), "Downloaded title")
        XCTAssertEqual(String(localized: String.LocalizationValue(stringLiteral: "swiftui.title"), bundle: patched), "App title")
    }

    // MARK: Fixtures

    /// The download for the storyboard `Main` and the xib `Card`: Tarjim custom bundles of those names.
    private static let interfaceText = [
        "Main": "\"lbl-01-xyz.text\" = \"Downloaded storyboard title\";",
        "Card": "\"xlb-01-xyz.text\" = \"Downloaded card\";",
    ]

    /// Any language other than the runner's, made the development language so the runner's becomes another one.
    private var otherLanguage: String { language == "de" ? "fr" : "de" }

    /// An app bundle holding the compiled interface files, with the given development language and, in the runner's
    /// language, the given tables. The development language's folder holds no interface tables, as Xcode lays it out.
    private func appBundle(developmentLanguage: String, tables: [String: String] = [:]) throws -> Bundle {
        let directory = try LookupFixtures.temporaryDirectory(for: self).appendingPathComponent("App.bundle", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: Fixtures.url("proxy-ui/Base.lproj"), to: directory.appendingPathComponent("Base.lproj"))
        let info: [String: Any] = ["CFBundleIdentifier": "com.example.app", "CFBundleDevelopmentRegion": developmentLanguage,
                                   "CFBundlePackageType": "BNDL"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: directory.appendingPathComponent("Info.plist"))
        var files = ["\(developmentLanguage).lproj/Localizable.strings": "\"development.only\" = \"Development\";"]
        for (table, text) in tables {
            files["\(language).lproj/\(table).strings"] = text
        }
        for (path, text) in files {
            let url = directory.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
        }
        let bundle = try XCTUnwrap(Bundle(url: directory))
        XCTAssertEqual(bundle.preferredLocalizations.first, tables.isEmpty ? developmentLanguage : language)
        return bundle
    }

    /// A resolver over a download in the runner's language: `Localizable` is the default bundle, any other table a
    /// custom bundle of that name.
    private func resolver(app: Bundle, download: [String: String]) throws -> Resolver {
        var entries = [ManifestBundle(id: "ns1", type: "namespace", name: "default")]
        var extra = ["ns1.bundle/\(language).lproj/Localizable.strings": download["Localizable"] ?? ""]
        for (index, (table, text)) in download.filter({ $0.key != "Localizable" }).sorted(by: { $0.key < $1.key }).enumerated() {
            entries.append(ManifestBundle(id: "b\(index + 1)", type: "custom", name: table))
            extra["b\(index + 1).bundle/\(language).lproj/Localizable.strings"] = text
        }
        return LookupFixtures.resolver(app: AppResources(bundle: app, language: language),
                                       install: try LookupFixtures.install(for: self, bundles: [], locales: [], extra: extra),
                                       selection: LocaleSelection(kind: .user, locales: [language]), entries: entries)
    }

    /// Installs the proxy over `download`; with `counting`, another library's patch first, counting the app's lookups.
    private func patch(_ bundle: Bundle, download: [String: String], counting: Bool = false) throws -> (Bundle, Resolver) {
        if counting {
            object_setClass(bundle, CountingBundle.self)
        }
        let resolver = try resolver(app: bundle, download: download)
        XCTAssertTrue(MainBundleProxy.install(on: bundle) { key, table in resolver.downloaded(key, table: table) })
        CountingBundle.reset()
        return (bundle, resolver)
    }

    @MainActor private func storyboardLabel(_ bundle: Bundle) -> String? {
        let controller = UIStoryboard(name: "Main", bundle: bundle).instantiateInitialViewController()
        return (controller?.view.viewWithTag(7) as? UILabel)?.text
    }

    @MainActor private func xibLabel(_ bundle: Bundle) -> String? {
        let view = UINib(nibName: "Card", bundle: bundle).instantiate(withOwner: nil).first as? UIView
        return (view?.viewWithTag(7) as? UILabel)?.text
    }

    /// Which candidate the view shows, compared as pixels against each candidate drawn verbatim.
    @MainActor private func shown<V: View, W: View>(_ view: V, among candidates: [String], as verbatim: (String) -> W) -> String? {
        let image = rendered(view)
        let drawn = candidates.map { ($0, rendered(verbatim($0))) }
        XCTAssertEqual(Set(drawn.map(\.1)).count, candidates.count, "distinct text must draw differently")
        return drawn.first { $0.1 == image }?.0
    }

    @MainActor private func shown<V: View>(_ view: V, among candidates: [String]) -> String? {
        shown(view, among: candidates, as: { Text(verbatim: $0) })
    }

    /// The view as a hosting controller in a window draws it: the environment SwiftUI gives an app's own screens.
    @MainActor private func rendered<V: View>(_ view: V) -> Data {
        let host = UIHostingController(rootView: view.fixedSize())
        let size = host.sizeThatFits(in: CGSize(width: 1_000, height: 1_000))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: max(size.width, 1), height: max(size.height, 1)))
        window.rootViewController = host
        window.isHidden = false
        defer { window.isHidden = true }
        host.view.frame = window.bounds
        host.view.layoutIfNeeded()
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(bounds: host.view.bounds, format: format).pngData { _ in
            _ = host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true)
        }
    }
}

/// The test runner's own main bundle, patched once per process; between tests it has no download and answers as before.
private enum MainBundleDownload {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var current: Resolver?

    static var resolver: Resolver? {
        get { lock.withLock { current } }
        set { lock.withLock { current = newValue } }
    }

    static let installed: Bool = {
        MainBundleProxy.install(on: .main) { key, table in resolver?.downloaded(key, table: table) }
        return MainBundleProxy.isInstalled(on: .main)
    }()
}
#endif
