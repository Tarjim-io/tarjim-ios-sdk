import Foundation
import XCTest
@testable import Tarjim

final class DeliveryEndpointTests: XCTestCase {
    func testMetaURLIsHostProjectsIdDeliveryMetaWithoutTrailingSlash() throws {
        let endpoint = try DeliveryEndpoint(host: URL(string: "https://api.example.invalid")!, projectId: 7, apiKey: "k")
        XCTAssertEqual(endpoint.metaURL.absoluteString, "https://api.example.invalid/projects/7/delivery/meta")
    }

    func testHostPortIsKept() throws {
        let endpoint = try DeliveryEndpoint(host: URL(string: "http://localhost:8080")!, projectId: 7, apiKey: "k")
        XCTAssertEqual(endpoint.metaURL.absoluteString, "http://localhost:8080/projects/7/delivery/meta")
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
                    "ftp://api.example.invalid", "api.example.invalid", "https://"] {
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
    func testUserAgentNamesSDKAppOSAndLanguage() {
        let identity = ClientIdentity(sdkVersion: "0.1.0", appVersion: "2.3.1", osVersion: "17.4", language: "ar", installIdentifier: nil)
        XCTAssertEqual(identity.userAgent, "Tarjim-iOS/0.1.0 app/2.3.1 iOS/17.4 lang/ar")
    }

    func testInstallIdentifierIsSentOnlyWhenSet() {
        var identity = ClientIdentity(sdkVersion: "0.1.0", appVersion: "2.3.1", osVersion: "17.4", language: "ar", installIdentifier: nil)
        XCTAssertFalse(identity.userAgent.contains("install/"))
        identity.installIdentifier = "8f2c1a"
        XCTAssertEqual(identity.userAgent, "Tarjim-iOS/0.1.0 app/2.3.1 iOS/17.4 lang/ar install/8f2c1a")
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
