import Foundation
import XCTest
@testable import Tarjim

final class DeliveryEndpointTests: XCTestCase {
    func testMetaURLIsHostProjectsIdDeliveryMetaWithoutTrailingSlash() throws {
        let endpoint = try DeliveryEndpoint(host: URL(string: "https://api.example.invalid")!, projectId: 7, apiKey: "k")
        XCTAssertEqual(endpoint.metaURL.absoluteString, "https://api.example.invalid/projects/7/delivery/meta")
    }

    /// Plain `http` would put the key on the wire in the clear; it is allowed for a local stack only.
    func testHostPortIsKeptAndHTTPIsAllowedForLoopbackOnly() throws {
        let endpoint = try DeliveryEndpoint(host: URL(string: "http://localhost:8080")!, projectId: 7, apiKey: "k")
        XCTAssertEqual(endpoint.metaURL.absoluteString, "http://localhost:8080/projects/7/delivery/meta")
        XCTAssertNoThrow(try DeliveryEndpoint(host: URL(string: "http://127.0.0.1:3000")!, projectId: 7, apiKey: "k"))
        XCTAssertNoThrow(try DeliveryEndpoint(host: URL(string: "http://[::1]:3000")!, projectId: 7, apiKey: "k"))
        XCTAssertNoThrow(try DeliveryEndpoint(host: URL(string: "https://api.example.invalid:8443")!, projectId: 7, apiKey: "k"))
    }

    /// A trailing slash on the host is harmless; the meta URL still has none (the CDN answers 403
    /// to `…/meta/`, and origin-relative URLs would resolve against the wrong segment).
    func testTrailingSlashOnHostIsNormalised() throws {
        let plain = try DeliveryEndpoint(host: URL(string: "https://api.example.invalid")!, projectId: 1, apiKey: "k")
        let slashed = try DeliveryEndpoint(host: URL(string: "https://api.example.invalid/")!, projectId: 1, apiKey: "k")
        XCTAssertEqual(slashed.metaURL, plain.metaURL)
        XCTAssertFalse(slashed.metaURL.absoluteString.hasSuffix("/"))
    }

    func testHostWithPathQueryFragmentOrOtherSchemeIsRefused() {
        for bad in ["https://api.example.invalid/api", "https://api.example.invalid/?x=1", "https://api.example.invalid#f",
                    "ftp://api.example.invalid", "api.example.invalid", "https://", "http://api.example.invalid",
                    "https://user@api.example.invalid"] {
            XCTAssertThrowsError(try DeliveryEndpoint(host: URL(string: bad) ?? URL(string: "file:///")!, projectId: 1, apiKey: "k"), bad) {
                XCTAssertEqual($0 as? DeliveryEndpoint.Error, .invalidHost, bad)
            }
        }
    }

    func testStoresProjectAndKey() throws {
        let endpoint = try DeliveryFixtures.endpoint()
        XCTAssertEqual(endpoint.projectId, DeliveryFixtures.projectId)
        XCTAssertEqual(endpoint.apiKey, DeliveryFixtures.apiKey)
    }
}

final class ClientIdentityTests: XCTestCase {
    /// Lower-case token names; `rel/0` and `poll/0` until a release is shown and a `pollAfter` obeyed.
    func testUserAgentNamesSDKAppOSLanguageReleaseAndPoll() {
        var identity = ClientIdentity(sdkVersion: "0.1.0", appVersion: "2.3.1", osVersion: "17.4", language: "ar", installIdentifier: nil)
        XCTAssertEqual(identity.userAgent, "Tarjim-iOS/0.1.0 app/2.3.1 ios/17.4 lang/ar rel/0 poll/0")
        identity.releaseId = 42
        identity.pollAfter = 1800
        XCTAssertEqual(identity.userAgent, "Tarjim-iOS/0.1.0 app/2.3.1 ios/17.4 lang/ar rel/42 poll/1800")
    }

    func testInstallIdentifierIsSentOnlyWhenSet() {
        var identity = ClientIdentity(sdkVersion: "0.1.0", appVersion: "2.3.1", osVersion: "17.4", language: "ar", installIdentifier: nil)
        XCTAssertFalse(identity.userAgent.contains("install/"))
        identity.installIdentifier = "8f2c1a"
        XCTAssertEqual(identity.userAgent, "Tarjim-iOS/0.1.0 app/2.3.1 ios/17.4 lang/ar rel/0 poll/0 install/8f2c1a")
    }

    /// Every value is percent-encoded, keeping RFC 3986's unreserved characters, so the line is always
    /// `token/value` pairs separated by single spaces.
    func testEveryValueIsPercentEncoded() {
        let identity = ClientIdentity(sdkVersion: "0.1.0", appVersion: "2.3.1", osVersion: "17.4 beta", language: "zh Hans/TW",
                                      installIdentifier: "a b")
        XCTAssertEqual(identity.userAgent, "Tarjim-iOS/0.1.0 app/2.3.1 ios/17.4%20beta lang/zh%20Hans%2FTW rel/0 poll/0 install/a%20b")
        let unreserved = ClientIdentity(sdkVersion: "0.1.0", appVersion: "2.3.1", osVersion: "17.4", language: "zh-Hant_TW.~",
                                        installIdentifier: nil)
        XCTAssertTrue(unreserved.userAgent.contains(" lang/zh-Hant_TW.~ "))
        let pairs = identity.userAgent.split(separator: " ", omittingEmptySubsequences: false)
        XCTAssertTrue(pairs.allSatisfy { $0.split(separator: "/").count == 2 }, identity.userAgent)
    }
}

/// The app's version as `X-Tarjim-App-Version` and `app/` carry it: always `MAJOR.MINOR.PATCH`.
final class AppVersionTests: XCTestCase {
    func testTheBundleVersionIsReducedToItsCore() {
        let cases: [(String, String)] = [
            ("2.3.1", "2.3.1"), ("2.1 beta", "2.1.0"), ("1.0-rc1", "1.0.0"), ("1.2.3+build.7", "1.2.3"), ("3", "3.0.0"),
            ("1.02", "1.2.0"), ("007.1.0", "7.1.0"), ("1.2.3.4", "1.2.3"), ("1..2", "1.0.0"), ("1.", "1.0.0"),
            ("beta", "0.0.0"), ("", "0.0.0"), (" 1.2", "0.0.0"), ("v1.2", "0.0.0"), ("-1.2", "0.0.0"),
            ("99999999999999999999.1", "0.0.0"), ("1.99999999999999999999", "0.0.0"),
        ]
        for (raw, core) in cases {
            XCTAssertEqual(AppVersion.core(of: raw), core, raw)
        }
    }

    func testTheCoreAlwaysMatchesTheServersGrammar() {
        let grammar = try! NSRegularExpression(pattern: #"^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$"#)
        for raw in ["", "x", "1", "1.2", "1.2.3", "1.2.3.4.5", "10.20.30-alpha", "0001", "1.0.0.0", String(repeating: "9", count: 40),
                    "12345678901.12345678901.1234567890"] {
            let core = AppVersion.core(of: raw)
            XCTAssertNotNil(grammar.firstMatch(in: core, range: NSRange(core.startIndex..., in: core)), "\(raw) → \(core)")
            XCTAssertLessThanOrEqual(core.count, 32, raw)
        }
    }
}

final class VerifierTests: XCTestCase {
    func testSHA256OfKnownVectors() {
        XCTAssertEqual(Verifier.sha256Hex(Data("abc".utf8)), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        XCTAssertEqual(Verifier.sha256Hex(Data()), "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
    }

    func testMatchesIsCaseInsensitiveAndExact() {
        let data = Data("abc".utf8)
        XCTAssertTrue(Verifier.matches(data, sha256Hex: "BA7816BF8F01CFEA414140DE5DAE2223B00361A396177A9CB410FF61F20015AD"))
        XCTAssertFalse(Verifier.matches(data, sha256Hex: "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ae"))
        XCTAssertFalse(Verifier.matches(data, sha256Hex: "ba7816bf"), "a prefix is not a match")
        XCTAssertFalse(Verifier.matches(data, sha256Hex: ""))
    }
}
