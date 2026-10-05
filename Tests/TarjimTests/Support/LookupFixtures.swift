import Foundation
import XCTest
@testable import Tarjim

/// An install directory built from the release-1 objects, and a stand-in for the app's own bundle.
enum LookupFixtures {
    static let entries = [
        ManifestBundle(id: "ns7", type: "namespace", name: "default"),
        ManifestBundle(id: "ns12", type: "namespace", name: "checkout"),
        ManifestBundle(id: "ns15", type: "namespace", name: "onboarding"),
        ManifestBundle(id: "b3", type: "custom", name: "checkout-screen"),
    ]

    static func temporaryDirectory(for test: XCTestCase) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("tarjim-lookup-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        test.addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    /// `<dir>/<bundleId>.bundle/<locale>.lproj/Localizable.{strings,stringsdict}` from the release-1 manifest,
    /// for the given bundles and locales, plus any extra `.strings` files given as text.
    static func install(for test: XCTestCase, bundles: [String] = ["ns7", "ns12", "ns15", "b3"], locales: [String] = ["en", "ar"],
                        extra: [String: String] = [:]) throws -> URL {
        let directory = try temporaryDirectory(for: test).appendingPathComponent("install", isDirectory: true)
        let manifest = try XCTUnwrap(JSONSerialization.jsonObject(with: Fixtures.data("release-1/manifest.json")) as? [String: Any])
        let slices = try XCTUnwrap(manifest["slices"] as? [String: [String: [String: [String: Any]]]])
        for bundleId in bundles {
            for locale in locales {
                for fileType in ["strings", "stringsdict"] {
                    guard let hash = slices[bundleId]?[locale]?[fileType]?["hash"] as? String else { continue }
                    try write(Fixtures.data("release-1/objects/\(hash).\(fileType)"),
                              to: directory.appendingPathComponent("\(bundleId).bundle/\(locale).lproj/Localizable.\(fileType)"))
                }
            }
        }
        for (path, text) in extra {
            try write(Data(text.utf8), to: directory.appendingPathComponent(path))
        }
        return directory
    }

    /// The app's own resources: `en` (development language) and `ar`, a `checkout` table in `en`.
    static func appBundle(for test: XCTestCase) throws -> Bundle {
        let directory = try temporaryDirectory(for: test).appendingPathComponent("App.bundle", isDirectory: true)
        let info: [String: Any] = ["CFBundleIdentifier": "com.example.app", "CFBundleDevelopmentRegion": "en", "CFBundlePackageType": "BNDL"]
        try write(PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0), to: directory.appendingPathComponent("Info.plist"))
        try write(Data("""
            "app.only" = "From the app";
            "count.only" = "%d left";
            "greeting" = "App hello, %@!";
            """.utf8), to: directory.appendingPathComponent("en.lproj/Localizable.strings"))
        try write(Data("""
            "app.only" = "From the checkout table";
            """.utf8), to: directory.appendingPathComponent("en.lproj/checkout.strings"))
        try write(Data("""
            "app.only" = "من التطبيق";
            """.utf8), to: directory.appendingPathComponent("ar.lproj/Localizable.strings"))
        try write(plural(["one": "%d app item", "other": "%d app items"]), to: directory.appendingPathComponent("en.lproj/Localizable.stringsdict"))
        try write(plural(["zero": "لا شيء", "one": "واحد", "two": "اثنان", "few": "%d قليلة", "many": "%d كثيرة", "other": "%d أخرى"]),
                  to: directory.appendingPathComponent("ar.lproj/Localizable.stringsdict"))
        return try XCTUnwrap(Bundle(url: directory))
    }

    static func app(for test: XCTestCase, language: String = "en") throws -> AppResources {
        AppResources(bundle: try appBundle(for: test), language: language)
    }

    static func resolver(app: AppResources, install: URL?, selection: LocaleSelection?, entries: [ManifestBundle] = entries,
                         defaultBundle: TarjimBundle = .namespace("default")) -> Resolver {
        let snapshot = Snapshot(installDirectory: install, entries: entries, selection: selection)
        return Resolver(app: app, defaultBundle: defaultBundle, snapshot: { snapshot })
    }

    private static func plural(_ forms: [String: String]) throws -> Data {
        var rule: [String: Any] = ["NSStringFormatSpecTypeKey": "NSStringPluralRuleType", "NSStringFormatValueTypeKey": "d"]
        rule.merge(forms) { $1 }
        let table: [String: Any] = ["app.items": ["NSStringLocalizedFormatKey": "%#@v@", "v": rule]]
        return try PropertyListSerialization.data(fromPropertyList: table, format: .xml, options: 0)
    }

    private static func write(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
    }
}
