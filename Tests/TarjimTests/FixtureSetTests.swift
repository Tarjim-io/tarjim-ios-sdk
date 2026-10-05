import Foundation
import XCTest
@testable import Tarjim

/// The fixture set is the server's side of every later test, so it must be internally consistent
/// and shaped like what the delivery routes really send.
final class FixtureSetTests: XCTestCase {
    private let release = "release-1"

    private func manifest() throws -> [String: Any] {
        let data = try Fixtures.data("\(release)/manifest.json")
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func slices() throws -> [String: [String: [String: [String: Any]]]] {
        try XCTUnwrap(manifest()["slices"] as? [String: [String: [String: [String: Any]]]], "manifest.slices has the wrong shape")
    }

    func testManifestChecksumMatchesMetaInBothModes() throws {
        let checksum = Fixtures.sha256Hex(try Fixtures.data("\(release)/manifest.json"))
        for mode in ["cdn", "origin"] {
            let meta = try Fixtures.envelope("\(release)/meta.\(mode).json")
            XCTAssertEqual(meta.status, 200, mode)
            XCTAssertEqual(try meta.jsonBody()["checksum"] as? String, checksum, "meta.\(mode).checksum")
        }
    }

    func testEveryManifestEntryHasItsObjectWithMatchingHashAndSize() throws {
        var count = 0
        for (bundle, byLocale) in try slices() {
            for (locale, byFileType) in byLocale {
                for (fileType, entry) in byFileType {
                    let hash = try XCTUnwrap(entry["hash"] as? String, "\(bundle)/\(locale)/\(fileType) hash")
                    let size = try XCTUnwrap(entry["size"] as? Int, "\(bundle)/\(locale)/\(fileType) size")
                    XCTAssertNotNil(entry["transferSize"] as? Int, "\(bundle)/\(locale)/\(fileType) transferSize")
                    let bytes = try Fixtures.data("\(release)/objects/\(hash).\(fileType)")
                    XCTAssertEqual(Fixtures.sha256Hex(bytes), hash, "\(bundle)/\(locale)/\(fileType)")
                    XCTAssertEqual(bytes.count, size, "\(bundle)/\(locale)/\(fileType)")
                    count += 1
                }
            }
        }
        XCTAssertGreaterThan(count, 0)
    }

    func testNoObjectIsUnlisted() throws {
        var listed = Set<String>()
        for byLocale in try slices().values {
            for byFileType in byLocale.values {
                for (fileType, entry) in byFileType {
                    listed.insert("\(entry["hash"] as? String ?? "?").\(fileType)")
                }
            }
        }
        let onDisk = try Fixtures.allFiles()
            .filter { $0.hasPrefix("\(release)/objects/") }
            .map { String($0.dropFirst("\(release)/objects/".count)) }
        XCTAssertEqual(Set(onDisk), listed)
    }

    /// A release lists both iOS files for every (bundle, locale), an empty one included, beside `json`.
    func testEveryBundleAndLocaleListsJsonStringsAndStringsdict() throws {
        let slices = try slices()
        XCTAssertGreaterThanOrEqual(slices.count, 3, "at least two namespaces and one custom bundle")
        for (bundle, byLocale) in slices {
            XCTAssertGreaterThanOrEqual(byLocale.count, 2, bundle)
            for (locale, byFileType) in byLocale {
                XCTAssertEqual(Set(byFileType.keys), ["json", "strings", "stringsdict"], "\(bundle)/\(locale)")
            }
        }
        let bundles = try XCTUnwrap(manifest()["bundles"] as? [String: [String: Any]])
        XCTAssertEqual(Set(bundles.keys), Set(slices.keys))
        XCTAssertTrue(bundles.values.contains { $0["type"] as? String == "custom" })
        XCTAssertTrue(bundles.values.contains { $0["type"] as? String == "namespace" })
    }

    /// Apple's own reader must accept every iOS object, the one-LF empty `.strings` included.
    func testAppleReadsEveryIOSObject() throws {
        let paths = try Fixtures.allFiles().filter { $0.hasSuffix(".strings") || $0.hasSuffix(".stringsdict") }
        XCTAssertGreaterThanOrEqual(paths.count, 8)
        for path in paths {
            let plist = try PropertyListSerialization.propertyList(from: Fixtures.data(path), format: nil)
            XCTAssertNotNil(plist as? [String: Any], path)
        }
    }

    func testMetaShapesForCdnAndOriginMode() throws {
        let cdn = try Fixtures.envelope("\(release)/meta.cdn.json").jsonBody()
        XCTAssertEqual(cdn["authenticated"] as? Bool, false)
        XCTAssertNotNil(cdn["signedQuery"] as? String)
        XCTAssertNotNil(cdn["signatureExpires"] as? Int)
        for field in ["manifestUrl", "slicesBaseUrl"] {
            let url = try XCTUnwrap(cdn[field] as? String, field)
            XCTAssertTrue(url.hasPrefix("https://"), "cdn \(field) is absolute")
            XCTAssertFalse(url.contains("?"), "cdn \(field) carries no query")
        }

        let origin = try Fixtures.envelope("\(release)/meta.origin.json").jsonBody()
        XCTAssertEqual(origin["authenticated"] as? Bool, true)
        XCTAssertNil(origin["signedQuery"], "origin mode has no signedQuery key at all")
        XCTAssertNil(origin["signatureExpires"])
        for field in ["manifestUrl", "slicesBaseUrl"] {
            let url = try XCTUnwrap(origin[field] as? String, field)
            XCTAssertFalse(url.contains("://") || url.hasPrefix("/") || url.contains("?"), "origin \(field) is path-relative")
        }

        for body in [cdn, origin] {
            XCTAssertEqual(body["schemaVersion"] as? Int, 1)
            XCTAssertNotNil(body["releaseId"] as? Int)
            XCTAssertNotNil(body["stage"] as? String)
            XCTAssertNotNil(body["track"] as? String)
            let pollAfter = try XCTUnwrap(body["pollAfter"] as? Int)
            XCTAssertTrue((60...3600).contains(pollAfter))
        }
    }

    func testErrorAnswersCoverEveryStatusTheSDKHandles() throws {
        // name → (status, problem code or nil when the body is not problem+json, pollAfter in the body or nil)
        let expected: [String: (Int, String?, Int?)] = [
            "meta-304": (304, nil, nil),
            "meta-400-validation": (400, "validation", nil),
            "meta-401-unauthorized": (401, "unauthorized", nil),
            "meta-403-apikey-project-mismatch": (403, "delivery.apikey_project_mismatch", nil),
            "meta-403-forbidden": (403, "forbidden", nil),
            "meta-404-track-not-found": (404, "delivery.track_not_found", 1800),
            "meta-404-stage-not-found": (404, "delivery.stage_not_found", 1800),
            "meta-404-stage-unreleased": (404, "delivery.stage_unreleased", 900),
            "meta-404-not-found": (404, "not-found", nil),
            "meta-429-too-many-requests": (429, "too-many-requests", nil),
            "meta-503-disabled": (503, "delivery.disabled", nil),
            "manifest-503-manifest-unavailable": (503, "delivery.manifest_unavailable", nil),
            "object-403-cdn-edge": (403, nil, nil),
            "object-404-slice-not-found": (404, "delivery.slice_not_found", nil),
        ]
        for (name, (status, code, pollAfter)) in expected {
            let envelope = try Fixtures.envelope("errors/\(name).json")
            XCTAssertEqual(envelope.status, status, name)
            if let code {
                XCTAssertEqual(envelope.header("Content-Type")?.hasPrefix("application/problem+json"), true, name)
                let body = try envelope.jsonBody()
                XCTAssertEqual(body["code"] as? String, code, name)
                XCTAssertEqual(body["status"] as? Int, status, name)
                XCTAssertEqual(body["pollAfter"] as? Int, pollAfter, "\(name) pollAfter")
            }
        }
        XCTAssertNil(try Fixtures.envelope("errors/meta-304.json").body, "a 304 has no body")
        let edge = try Fixtures.envelope("errors/object-403-cdn-edge.json")
        XCTAssertNil(edge.body.flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) }, "an edge 403 is not JSON")
        XCTAssertEqual(try Fixtures.envelope("errors/manifest-503-manifest-unavailable.json").header("Retry-After"), "30")
        XCTAssertNotNil(try Fixtures.envelope("errors/meta-429-too-many-requests.json").header("Retry-After"))
        XCTAssertNotNil(try Fixtures.envelope("errors/meta-400-validation.json").jsonBody()["supported"])
    }

    func testEveryEnvelopeDeclaresItsProvenance() throws {
        let envelopes = try Fixtures.allFiles().filter { $0.hasSuffix(".json") && !$0.hasSuffix("manifest.json") }
        XCTAssertFalse(envelopes.isEmpty)
        for path in envelopes {
            XCTAssertTrue(["hand-built", "recorded"].contains(try Fixtures.envelope(path).provenance), path)
        }
    }

    func testGoldenServerFilesArePresent() throws {
        for path in ["golden/corpus.strings", "golden/corpus.stringsdict"] {
            XCTAssertFalse(try Fixtures.data(path).isEmpty, path)
        }
    }

    /// This repository is public: a recorded fixture must never carry a key, a live signature or a
    /// real hostname.
    func testNoFixtureCarriesAKeyASignatureOrARealHost() throws {
        let paths = try Fixtures.allFiles()
        XCTAssertGreaterThanOrEqual(paths.count, 20)
        for path in paths {
            guard let text = String(data: try Fixtures.data(path), encoding: .utf8) else { continue }
            XCTAssertEqual(try PublicSafety.leaks(in: text), [], path)
        }
    }

    func testLeakScanCatchesAKeyASignatureAndAHost() throws {
        XCTAssertEqual(try PublicSafety.leaks(in: #"{"k":"tarjim-12-345-6-abcdef"}"#), ["API key"])
        XCTAssertEqual(try PublicSafety.leaks(in: "Policy=eyJTdGF0&Signature=REDACTED"), ["signature Policy"])
        XCTAssertEqual(try PublicSafety.leaks(in: "https://d1abc.cloudfront.net/releases/1/2/"), ["host d1abc.cloudfront.net"])
        XCTAssertEqual(try PublicSafety.leaks(in: "https://staging.example.org/x"), ["host staging.example.org"])
        XCTAssertEqual(try PublicSafety.leaks(in: "https://cdn.example.invalid/x?Policy=REDACTED&Signature=REDACTED&Key-Pair-Id=REDACTED"), [])
        XCTAssertEqual(try PublicSafety.leaks(in: "https://api.tarjim.io/problems/not-found"), [])
        XCTAssertEqual(try PublicSafety.leaks(in: "https://cdn.example.com/a.png"), [])
        XCTAssertEqual(try PublicSafety.leaks(in: "https://notexample.com/a.png"), ["host notexample.com"])
    }
}

enum PublicSafety {
    private static let allowedHosts = ["example.com", "www.apple.com", "api.tarjim.io"]

    /// What in `text` must not reach a public repository: an API key, a signature value other than
    /// `REDACTED`, or a host outside the `.invalid` TLD and a short allow-list.
    static func leaks(in text: String) throws -> [String] {
        let range = NSRange(text.startIndex..., in: text)
        func capture(_ match: NSTextCheckingResult, _ group: Int) -> String {
            String(text[Range(match.range(at: group), in: text)!])
        }
        var found: [String] = []
        if try NSRegularExpression(pattern: #"tarjim-\d+-\d+-\d+-"#).firstMatch(in: text, range: range) != nil {
            found.append("API key")
        }
        for match in try NSRegularExpression(pattern: #"(Policy|Signature|Key-Pair-Id|Expires)=([^&"\s\\]+)"#).matches(in: text, range: range)
        where capture(match, 2) != "REDACTED" {
            found.append("signature \(capture(match, 1))")
        }
        let hostPattern = try NSRegularExpression(pattern: #"[a-z][a-z0-9+.-]*://([^/\s"'?#:\\]+)"#, options: [.caseInsensitive])
        for match in hostPattern.matches(in: text, range: range) {
            let host = capture(match, 1).lowercased()
            if !(host.hasSuffix(".invalid") || allowedHosts.contains { host == $0 || host.hasSuffix("." + $0) }) {
                found.append("host \(host)")
            }
        }
        return found
    }
}
