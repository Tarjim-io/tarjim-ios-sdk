import Foundation
import XCTest
@testable import Tarjim

/// The fixture set is the server's side of every later test, so it must be internally consistent
/// and shaped like what the delivery routes really send.
///
/// `release-1/` is hand-built and holds both delivery modes; a recording made by
/// `scripts/capture-fixtures.sh` lands in `recorded/<name>/` with the same layout and one mode.
final class FixtureSetTests: XCTestCase {
    private static let handBuilt = "release-1"

    /// Every directory holding a release: the hand-built one and each recording.
    private func releases() throws -> [String] {
        let dirs = Set(try Fixtures.allFiles().filter { $0.hasSuffix("/manifest.json") }.map { String($0.dropLast("/manifest.json".count)) })
        XCTAssertTrue(dirs.contains(Self.handBuilt))
        return dirs.sorted()
    }

    private func metaModes(_ release: String) throws -> [String] {
        try ["cdn", "origin"].filter { FileManager.default.fileExists(atPath: try Fixtures.url("\(release)/meta.\($0).json").path) }
    }

    private func manifest(_ release: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Fixtures.data("\(release)/manifest.json")) as? [String: Any])
    }

    private func slices(_ release: String) throws -> [String: [String: [String: [String: Any]]]] {
        try XCTUnwrap(manifest(release)["slices"] as? [String: [String: [String: [String: Any]]]], "\(release): manifest.slices has the wrong shape")
    }

    func testManifestChecksumMatchesMetaInBothModes() throws {
        XCTAssertEqual(try metaModes(Self.handBuilt), ["cdn", "origin"], "the hand-built release holds both modes")
        for release in try releases() {
            let checksum = Fixtures.sha256Hex(try Fixtures.data("\(release)/manifest.json"))
            let modes = try metaModes(release)
            XCTAssertFalse(modes.isEmpty, "\(release) has no meta")
            for mode in modes {
                let meta = try Fixtures.envelope("\(release)/meta.\(mode).json")
                XCTAssertEqual(meta.status, 200, "\(release) \(mode)")
                XCTAssertEqual(try meta.jsonBody()["checksum"] as? String, checksum, "\(release) meta.\(mode).checksum")
            }
        }
    }

    func testEveryManifestEntryHasItsObjectWithMatchingHashAndSize() throws {
        for release in try releases() {
            var count = 0
            for (bundle, byLocale) in try slices(release) {
                for (locale, byFileType) in byLocale {
                    for (fileType, entry) in byFileType {
                        let slot = "\(release) \(bundle)/\(locale)/\(fileType)"
                        let hash = try XCTUnwrap(entry["hash"] as? String, "\(slot) hash")
                        let size = try XCTUnwrap(entry["size"] as? Int, "\(slot) size")
                        XCTAssertNotNil(entry["transferSize"] as? Int, "\(slot) transferSize")
                        let bytes = try Fixtures.data("\(release)/objects/\(hash).\(fileType)")
                        XCTAssertEqual(Fixtures.sha256Hex(bytes), hash, slot)
                        XCTAssertEqual(bytes.count, size, slot)
                        count += 1
                    }
                }
            }
            XCTAssertGreaterThan(count, 0, release)
        }
    }

    func testNoObjectIsUnlisted() throws {
        let files = try Fixtures.allFiles()
        for release in try releases() {
            var listed = Set<String>()
            for byLocale in try slices(release).values {
                for byFileType in byLocale.values {
                    for (fileType, entry) in byFileType {
                        listed.insert("\(entry["hash"] as? String ?? "?").\(fileType)")
                    }
                }
            }
            let prefix = "\(release)/objects/"
            let onDisk = files.filter { $0.hasPrefix(prefix) }.map { String($0.dropFirst(prefix.count)) }
            XCTAssertEqual(Set(onDisk), listed, release)
        }
    }

    /// A release lists both iOS files for every (bundle, locale), an empty one included, beside `json`.
    func testEveryBundleAndLocaleListsJsonStringsAndStringsdict() throws {
        let slices = try slices(Self.handBuilt)
        XCTAssertGreaterThanOrEqual(slices.count, 3, "at least two namespaces and one custom bundle")
        for (bundle, byLocale) in slices {
            XCTAssertGreaterThanOrEqual(byLocale.count, 2, bundle)
            for (locale, byFileType) in byLocale {
                XCTAssertEqual(Set(byFileType.keys), ["json", "strings", "stringsdict"], "\(bundle)/\(locale)")
            }
        }
        let bundles = try XCTUnwrap(manifest(Self.handBuilt)["bundles"] as? [String: [String: Any]])
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
        let etag = try NSRegularExpression(pattern: #"^"m\d+-[0-9a-f]{64}-p\d+(-c(\d+))?"$"#)
        for release in try releases() {
            for mode in try metaModes(release) {
                let envelope = try Fixtures.envelope("\(release)/meta.\(mode).json")
                let body = try envelope.jsonBody()
                let label = "\(release) \(mode)"
                if mode == "cdn" {
                    XCTAssertEqual(body["authenticated"] as? Bool, false, label)
                    XCTAssertNotNil(body["signedQuery"] as? String, label)
                    XCTAssertNotNil(body["signatureExpires"] as? Int, label)
                } else {
                    XCTAssertEqual(body["authenticated"] as? Bool, true, label)
                    XCTAssertNil(body["signedQuery"], "\(label): origin mode has no signedQuery key at all")
                    XCTAssertNil(body["signatureExpires"], label)
                }
                for field in ["manifestUrl", "slicesBaseUrl"] {
                    let url = try XCTUnwrap(body[field] as? String, "\(label) \(field)")
                    XCTAssertFalse(url.contains("?"), "\(label) \(field) carries no query")
                    if mode == "cdn" {
                        XCTAssertTrue(url.hasPrefix("https://"), "\(label) \(field) is absolute")
                    } else {
                        XCTAssertFalse(url.contains("://") || url.hasPrefix("/"), "\(label) \(field) is path-relative")
                    }
                }
                XCTAssertEqual(body["schemaVersion"] as? Int, 1, label)
                XCTAssertNotNil(body["releaseId"] as? Int, label)
                XCTAssertNotNil(body["stage"] as? String, label)
                XCTAssertNotNil(body["track"] as? String, label)
                // A monotone counter in unix seconds, never a date string.
                XCTAssertTrue(body["resultsLastUpdate"] is NSNull || body["resultsLastUpdate"] is Int, "\(label) resultsLastUpdate")
                let pollAfter = try XCTUnwrap(body["pollAfter"] as? Int, label)
                XCTAssertTrue((60...3600).contains(pollAfter), label)

                let tag = try XCTUnwrap(envelope.header("ETag"), "\(label) ETag")
                let match = try XCTUnwrap(etag.firstMatch(in: tag, range: NSRange(tag.startIndex..., in: tag)), "\(label) ETag \(tag)")
                XCTAssertEqual(match.range(at: 2).location != NSNotFound, mode == "cdn", "\(label): only CDN mode adds a bucket")
                if mode == "cdn", let bucket = Range(match.range(at: 2), in: tag).flatMap({ Int(tag[$0]) }) {
                    // The bucket is floor(epoch / 30 s), not an epoch.
                    XCTAssertLessThan(bucket, 100_000_000, "\(label) ETag bucket")
                }
            }
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
            "meta-429-invalid-key-limiter": (429, "too-many-requests", nil),
            "meta-500-cdn-signing-failed": (500, "delivery.cdn_signing_failed", nil),
            "meta-502-upstream-error": (502, "upstream-error", nil),
            "meta-503-disabled": (503, "delivery.disabled", nil),
            "meta-503-cdn-edge": (503, nil, nil),
            "manifest-404-manifest-not-found": (404, "delivery.manifest_not_found", nil),
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
        for edge in ["object-403-cdn-edge", "meta-503-cdn-edge"] {
            let body = try Fixtures.envelope("errors/\(edge).json").body
            XCTAssertNil(body.flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) }, "\(edge) is not JSON")
        }
        XCTAssertEqual(try Fixtures.envelope("errors/manifest-503-manifest-unavailable.json").header("Retry-After"), "30")
        XCTAssertNotNil(try Fixtures.envelope("errors/meta-429-too-many-requests.json").header("Retry-After"), "the per-key throttle")
        XCTAssertNil(try Fixtures.envelope("errors/meta-429-invalid-key-limiter.json").header("Retry-After"), "the invalid-key limiter")
        XCTAssertNotNil(try Fixtures.envelope("errors/meta-400-validation.json").jsonBody()["supported"])
    }

    /// The API echoes its version header on every answer; an answer made at the CDN edge does not.
    func testApiAnswersEchoTheVersionHeader() throws {
        let fromTheEdge: Set<String> = ["errors/object-403-cdn-edge.json", "errors/meta-503-cdn-edge.json"]
        let envelopes = try envelopePaths().filter { !fromTheEdge.contains($0) && !$0.contains("/objects/") }
        XCTAssertGreaterThanOrEqual(envelopes.count, 19)
        for path in envelopes {
            XCTAssertNotNil(try Fixtures.envelope(path).header("X-Tarjim-Api-Version"), path)
        }
    }

    func testEveryEnvelopeDeclaresItsProvenance() throws {
        let envelopes = try envelopePaths()
        XCTAssertGreaterThanOrEqual(envelopes.count, 21)
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
            XCTAssertEqual(try PublicSafety.leaks(in: Fixtures.data(path)), [], path)
        }
    }

    func testLeakScanCatchesAKeyASignatureAndAHost() throws {
        func leaks(_ text: String) throws -> [String] { try PublicSafety.leaks(in: Data(text.utf8)) }
        XCTAssertEqual(try leaks(#"{"k":"tarjim-12-345-6-abcdef"}"#), ["API key"])
        XCTAssertEqual(try leaks("Policy=eyJTdGF0&Signature=REDACTED"), ["signature Policy"])
        XCTAssertEqual(try leaks("https://d1abc.cloudfront.net/releases/1/2/"), ["host d1abc.cloudfront.net"])
        XCTAssertEqual(try leaks("https://staging.example.org/x"), ["host staging.example.org"])
        XCTAssertEqual(try leaks("https://notexample.com/a.png"), ["host notexample.com"])
        // Forms a recording really produces: escaped, encoded, bare, lower-case, subdomains of allowed hosts.
        XCTAssertEqual(try leaks(#"{"detail":"upstream staging-api.corp-internal.net rejected"}"#), ["host staging-api.corp-internal.net"])
        XCTAssertEqual(try leaks(#""https:\/\/d1abc.cloudfront.net\/x""#), ["host d1abc.cloudfront.net"])
        XCTAssertEqual(try leaks("https%3A%2F%2Fd1abc.cloudfront.net%2Fx%3FSignature%3DLIVESIG"), ["signature Signature", "host d1abc.cloudfront.net"])
        XCTAssertEqual(try leaks("https://zz-fixture-probe.api.tarjim.io/x"), ["host zz-fixture-probe.api.tarjim.io"])
        XCTAssertEqual(try leaks(#"{"k":"tarjim-12-345-6-abcdef"}"#), ["API key"])
        XCTAssertEqual(try leaks(#"Signature=LIVESIG"#), ["signature Signature"])
        XCTAssertEqual(try leaks("policy=LIVE&signature=LIVE"), ["signature policy", "signature signature"])
        XCTAssertEqual(try PublicSafety.leaks(in: Data([0xE9]) + Data(" https://d1abc.cloudfront.net/".utf8)), ["host d1abc.cloudfront.net"])
        XCTAssertEqual(try leaks("see staging.acme.com for details"), ["host staging.acme.com"])
        // Allowed.
        XCTAssertEqual(try leaks("https://cdn.example.invalid/x?Policy=REDACTED&Signature=REDACTED&Key-Pair-Id=REDACTED"), [])
        XCTAssertEqual(try leaks("https://api.tarjim.io/problems/not-found"), [])
        XCTAssertEqual(try leaks("https://cdn.example.com/a.png"), [])
        XCTAssertEqual(try leaks(#"<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">"#), [])
        XCTAssertEqual(try leaks(#""app.title" = "Tarjim"; "files.owner" = "%1$@ has %2$d files";"#), [])
    }

    private func envelopePaths() throws -> [String] {
        // Manifests and `objects/` hold raw served bytes, not envelopes.
        try Fixtures.allFiles().filter { $0.hasSuffix(".json") && !$0.hasSuffix("manifest.json") && !$0.contains("/objects/") }
    }
}

enum PublicSafety {
    private static let allowedHosts = ["www.apple.com", "api.tarjim.io"]
    private static let allowedDomains = ["example.com", "invalid"]
    private static let tlds = "com|net|org|io|dev|cloud|ai|co|me|info|biz|tech|site|xyz|internal|local|corp|lan|intranet|aws"

    /// What in `bytes` must not reach a public repository: an API key, a signature value other than
    /// `REDACTED`, or a host outside `*.invalid`, `*.example.com` and two exact hosts. The text is
    /// also scanned with JSON and percent escapes undone, and bytes that are not UTF-8 are read as
    /// Latin-1, so neither hides a match.
    static func leaks(in bytes: Data) throws -> [String] {
        let text = String(data: bytes, encoding: .utf8) ?? String(data: bytes, encoding: .isoLatin1)!
        let unescaped = unescapeJSON(text)
        let variants = [text, unescaped, unescaped.removingPercentEncoding ?? unescaped]

        var found: [String] = []
        func add(_ item: String) {
            if !found.contains(item) { found.append(item) }
        }
        for text in variants {
            let range = NSRange(text.startIndex..., in: text)
            func capture(_ match: NSTextCheckingResult, _ group: Int) -> String {
                String(text[Range(match.range(at: group), in: text)!])
            }
            if try NSRegularExpression(pattern: #"tarjim-\d+-\d+-\d+-"#, options: [.caseInsensitive]).firstMatch(in: text, range: range) != nil {
                add("API key")
            }
            let signature = try NSRegularExpression(pattern: #"\b(Policy|Signature|Key-Pair-Id|Expires)=([^&"\s\\]+)"#, options: [.caseInsensitive])
            for match in signature.matches(in: text, range: range) where capture(match, 2) != "REDACTED" {
                add("signature \(capture(match, 1))")
            }
            let withScheme = try NSRegularExpression(pattern: #"[a-z][a-z0-9+.-]*://([^/\s"'?#:\\%]+)"#, options: [.caseInsensitive])
            let bare = try NSRegularExpression(pattern: #"(?<![\w.@%-])((?:[a-z0-9](?:[a-z0-9-]*[a-z0-9])?\.)+(?:\#(tlds)))(?![\w-])"#, options: [.caseInsensitive])
            for match in withScheme.matches(in: text, range: range) + bare.matches(in: text, range: range) {
                let host = capture(match, 1).lowercased()
                if !isAllowed(host) { add("host \(host)") }
            }
        }
        return found
    }

    private static func isAllowed(_ host: String) -> Bool {
        allowedHosts.contains(host) || allowedDomains.contains { host == $0 || host.hasSuffix("." + $0) }
    }

    private static func unescapeJSON(_ text: String) -> String {
        var result = text.replacingOccurrences(of: #"\/"#, with: "/")
        let unicode = try! NSRegularExpression(pattern: #"\\u([0-9a-fA-F]{4})"#)
        for match in unicode.matches(in: result, range: NSRange(result.startIndex..., in: result)).reversed() {
            let range = Range(match.range, in: result)!
            let hex = String(result[Range(match.range(at: 1), in: result)!])
            if let scalar = UInt32(hex, radix: 16).flatMap(Unicode.Scalar.init) {
                result.replaceSubrange(range, with: String(Character(scalar)))
            }
        }
        return result
    }
}
