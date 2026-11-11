import Foundation
import XCTest
@testable import Tarjim

final class DeliveryEndpointTests: XCTestCase {
    private let deliveryURL = URL(string: "https://api.example.invalid/t/7/projects/1/delivery/meta")!

    /// The delivery URL the console shows is the `meta` URL itself; the SDK sends it as given.
    func testTheDeliveryURLIsTheMetaURLAsGiven() throws {
        let endpoint = try DeliveryEndpoint(deliveryURL: deliveryURL, apiKey: "k")
        XCTAssertEqual(endpoint.metaURL, deliveryURL)
        XCTAssertEqual(endpoint.apiKey, "k")
    }

    /// The path is the server's business: any path is taken as it is, never parsed or rebuilt.
    func testAnyPathIsTakenAsItIs() throws {
        for path in ["/t/7/projects/1/delivery/meta", "/projects/1/delivery/meta", "/a/b/c", "/meta"] {
            let url = URL(string: "https://cdn.example.invalid\(path)")!
            XCTAssertEqual(try DeliveryEndpoint(deliveryURL: url, apiKey: "k").metaURL, url, path)
        }
    }

    /// Plain `http` would put the key on the wire in the clear; it is allowed for a local stack only.
    func testHTTPIsAllowedForLoopbackOnlyAndPortsAreKept() throws {
        for good in ["http://localhost:8080/t/1/projects/1/delivery/meta", "http://127.0.0.1:3000/x/meta",
                     "http://[::1]:3000/x/meta", "https://api.example.invalid:8443/t/1/projects/1/delivery/meta"] {
            let url = URL(string: good)!
            XCTAssertEqual(try DeliveryEndpoint(deliveryURL: url, apiKey: "k").metaURL, url, good)
        }
    }

    /// A trailing slash would make origin-relative references resolve against the wrong segment; a query, fragment
    /// or credentials have no place in it.
    func testADeliveryURLThatIsNotAMetaURLIsRefused() {
        for bad in ["https://api.example.invalid/t/7/projects/1/delivery/meta/", "https://api.example.invalid",
                    "https://api.example.invalid/", "https://api.example.invalid/t/7/projects/1/delivery/meta?x=1",
                    "https://api.example.invalid/t/7/projects/1/delivery/meta#f", "https://user@api.example.invalid/x/meta",
                    "https://user:pw@api.example.invalid/x/meta", "http://api.example.invalid/x/meta", "ftp://api.example.invalid/x/meta",
                    "api.example.invalid/x/meta", "https:///x/meta"] {
            XCTAssertThrowsError(try DeliveryEndpoint(deliveryURL: URL(string: bad) ?? URL(string: "file:///")!, apiKey: "k"), bad) {
                XCTAssertEqual($0 as? DeliveryEndpoint.Error, .invalidDeliveryURL, bad)
            }
        }
    }
}

/// The edges a pasted or hand-typed delivery URL can have.
final class DeliveryURLEdgeTests: XCTestCase {
    private func refused(_ string: String, file: StaticString = #filePath, line: UInt = #line) {
        guard let url = URL(string: string) else { return XCTFail("\(string) does not parse", file: file, line: line) }
        XCTAssertThrowsError(try DeliveryEndpoint(deliveryURL: url, apiKey: "k"), string, file: file, line: line) {
            XCTAssertEqual($0 as? DeliveryEndpoint.Error, .invalidDeliveryURL, string, file: file, line: line)
        }
    }

    /// Dot segments make the request path and the base for origin references disagree.
    func testDotSegmentsAreRefused() {
        for path in ["/t/7/projects/1/delivery/meta/.", "/t/7/projects/1/delivery/meta/..", "/t/7/../projects/1/delivery/meta",
                     "/t/7/./projects/1/delivery/meta", "/t/7/%2e%2e/projects/1/delivery/meta", "/t/7/projects/1/delivery/meta/%2E"] {
            refused("https://api.example.invalid\(path)")
        }
    }

    /// Whitespace or control characters, encoded or not, mean a bad paste, not a URL the server serves.
    func testWhitespaceIsRefused() {
        for bad in ["https://api.example.invalid/t/7/projects/1/delivery/meta%20", "https://api.example.invalid/t/7/projects/1/delivery/meta%0A",
                    "https://api.example.invalid/t/7/projects%091/delivery/meta"] {
            refused(bad)
        }
    }

    func testControlAndInvisibleCharactersAreRefused() {
        for bad in ["https://api.example.invalid/t/7/projects/1/delivery/meta%00", "https://api.example.invalid/t/7/projects/1/delivery/meta%7F",
                    "https://api.example.invalid/t/7/projects/1/delivery/meta%E2%80%8B"] {
            refused(bad)
        }
    }

    /// An internationalised host in the ASCII form a console shows is an ordinary host.
    func testAPunycodeHostIsAccepted() throws {
        let url = URL(string: "https://xn--bcher-kva.example.invalid/t/7/projects/1/delivery/meta")!
        XCTAssertEqual(try DeliveryEndpoint(deliveryURL: url, apiKey: "k").metaURL, url)
    }

    /// Plain http is for exactly these loopback names; anything that merely looks local is not.
    func testOnlyLoopbackItselfMayUseHTTP() {
        for bad in ["http://0.0.0.0/x/meta", "http://localhost.example.invalid/x/meta", "http://mylocalhost/x/meta",
                    "http://localhost./x/meta", "http://127.0.0.2/x/meta", "http://%6c%6fcalhost/x/meta", "http://[::ffff:127.0.0.1]/x/meta"] {
            refused(bad)
        }
    }
}

/// The runtime reads `meta` from the URL it was given, with nothing added.
final class DeliveryURLWiringTests: XCTestCase {
    func testTheRuntimeRequestsTheConfiguredURL() async throws {
        let harness = try RuntimeHarness(self)
        harness.server.publish(try Release.one())
        let configured = URL(string: "https://cdn.example.invalid/t/42/projects/9/delivery/meta")!
        let runtime = try harness.make(harness.configuration(deliveryURL: configured))
        await runtime.start(foreground: true)
        await runtime.checkNow()
        XCTAssertEqual(MetaRequest.withoutQuery(harness.server.metaRequests.first?.url), configured)
    }
}

final class TarjimConfigurationTests: XCTestCase {
    func testTheConfigurationTakesOneDeliveryURL() {
        let url = URL(string: "https://api.example.invalid/t/7/projects/1/delivery/meta")!
        let configuration = TarjimConfiguration(deliveryURL: url, apiKey: "k", defaultBundle: .namespace("default"),
                                                fallbackLanguage: "en")
        XCTAssertEqual(configuration.deliveryURL, url)
    }
}

final class ClientIdentityTests: XCTestCase {
    private let full = ClientIdentity(sdkVersion: "0.1.0", appVersion: "2.3.1", osVersion: "17.4", language: "ar",
                                      installIdentifier: "8f2c1a", releaseId: 42, appBuild: "77")

    /// The User-Agent names the SDK and nothing else; everything about the app goes in the `meta` query.
    func testTheUserAgentIsOnlyTheSDK() {
        XCTAssertEqual(full.userAgent, "Tarjim-iOS/0.1.0")
    }

    /// In this order; `release` is 0 until a release is shown. There is no polling interval to report.
    func testTheMetaQueryNamesTheAppAndTheRelease() {
        XCTAssertEqual(full.metaQuery, "appVersion=2.3.1&platform=ios&sdkVersion=0.1.0&release=42"
                       + "&language=ar&osVersion=17.4&installId=8f2c1a&appBuild=77")
        let fresh = ClientIdentity(sdkVersion: "0.1.0", appVersion: "2.3.1", osVersion: "17.4", language: "ar", installIdentifier: nil)
        XCTAssertEqual(fresh.metaQuery, "appVersion=2.3.1&platform=ios&sdkVersion=0.1.0&release=0&language=ar&osVersion=17.4")
    }

    /// An app with no usable version sends no `appVersion` at all, and the server serves it as the newest app.
    func testNoVersionMeansNoAppVersionParameter() {
        let unversioned = ClientIdentity(sdkVersion: "0.1.0", appVersion: nil, osVersion: "17.4", language: "ar", installIdentifier: nil)
        XCTAssertEqual(unversioned.metaQuery, "platform=ios&sdkVersion=0.1.0&release=0&language=ar&osVersion=17.4")
    }

    /// Every value is percent-encoded, keeping RFC 3986's unreserved characters, so no value can add a parameter.
    func testEveryValueIsPercentEncoded() {
        let odd = ClientIdentity(sdkVersion: "0.1.0", appVersion: "2.3.1", osVersion: "17.4 beta", language: "zh Hans/TW&x=1+y",
                                 installIdentifier: "a b", appBuild: "1#2")
        XCTAssertEqual(odd.metaQuery, "appVersion=2.3.1&platform=ios&sdkVersion=0.1.0&release=0"
                       + "&language=zh%20Hans%2FTW%26x%3D1%2By&osVersion=17.4%20beta&installId=a%20b&appBuild=1%232")
        let unreserved = ClientIdentity(sdkVersion: "0.1.0", appVersion: "2.3.1", osVersion: "17.4", language: "zh-Hant_TW.~",
                                        installIdentifier: nil)
        XCTAssertTrue(unreserved.metaQuery.contains("&language=zh-Hant_TW.~&"))
    }
}

/// The app's version as the `appVersion` query parameter carries it: `MAJOR.MINOR.PATCH`, or nothing at all.
/// The same rules as the JavaScript SDK's, so one app version means one release on every platform.
final class AppVersionTests: XCTestCase {
    func testTheBundleVersionIsReducedToItsCore() {
        let cases: [(String, String?)] = [
            ("2.3.1", "2.3.1"), ("2.1 beta", "2.1.0"), ("1.0-rc1", "1.0.0"), ("1.2.3+build.7", "1.2.3"), ("3", "3.0.0"),
            ("1.02", "1.2.0"), ("007.1.0", "7.1.0"), ("1.2.3.4", "1.2.3"), ("1.", "1.0.0"), ("0", "0.0.0"),
            ("2.1.0-rc1", "2.1.0"), ("2.1.0+5", "2.1.0"), ("1.2.x", "1.2.0"), ("1.2.3.", "1.2.3"), ("1.2.3..4", "1.2.3"),
            ("1.2.3.99999999999999999999", "1.2.3"),
            // A leading lowercase `v` is a common spelling of a version; anything else before the digits is not one.
            ("v1.2", "1.2.0"), ("v2.3.1-beta", "2.3.1"),
            ("V1.2", nil), ("vv1", nil), ("v", nil), (" 1.2", nil), ("-1.2", nil), ("beta", nil), ("", nil), (".", nil), (".5", nil),
            // An empty part between dots is not a zero.
            ("1..2", nil), ("1.2..3", nil), ("1..", nil), ("1.2..", nil),
            ("00", "0.0.0"), ("0.00.000", "0.0.0"),
            // Nine digits a part at most, counted after leading zeros go.
            ("123456789.1", "123456789.1.0"), ("1234567890.1", nil), ("1.1234567890", nil), ("0000000001.2", "1.2.0"),
            ("99999999999999999999.1", nil), ("1.99999999999999999999", nil),
            // Only ASCII digits are digits.
            ("\u{0661}.\u{0662}", nil), ("1.\u{0662}", "1.0.0"),
            // A combining mark ends the digits it follows, as it does in the JavaScript SDK.
            ("1\u{0301}.2", "1.0.0"), ("1.2\u{0301}", "1.2.0"),
        ]
        for (raw, core) in cases {
            XCTAssertEqual(AppVersion.core(of: raw), core, raw)
        }
    }

    func testNoBundleVersionIsNoVersion() {
        XCTAssertNil(AppVersion.core(of: nil))
    }

    func testTheCoreAlwaysMatchesTheServersGrammar() {
        let grammar = try! NSRegularExpression(pattern: #"^(0|[1-9][0-9]{0,8})\.(0|[1-9][0-9]{0,8})\.(0|[1-9][0-9]{0,8})$"#)
        for raw in ["", "x", "1", "1.2", "1.2.3", "1.2.3.4.5", "10.20.30-alpha", "0001", "1.0.0.0", String(repeating: "9", count: 40),
                    "12345678901.12345678901.1234567890", "999999999.999999999.999999999", "v0.0.0"] {
            guard let core = AppVersion.core(of: raw) else { continue }
            XCTAssertNotNil(grammar.firstMatch(in: core, range: NSRange(core.startIndex..., in: core)), "\(raw) → \(core)")
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
