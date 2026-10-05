import Foundation
import XCTest
@testable import Tarjim

final class DeliveryClientManifestTests: XCTestCase {
    private func fetch(_ meta: Meta, _ answer: FakeTransport.Answer?) async throws -> (ManifestOutcome, FakeTransport) {
        let transport = FakeTransport()
        if let answer { transport.enqueue(answer) }
        let outcome = try await DeliveryFixtures.client(transport).fetchManifest(meta)
        return (outcome, transport)
    }

    private func manifestAnswer(_ bytes: Data? = nil) throws -> FakeTransport.Answer {
        FakeTransport.Answer(status: 200, headers: ["Content-Type": "application/json; charset=utf-8"], body: try bytes ?? DeliveryFixtures.manifestBytes())
    }

    // MARK: origin mode

    func testOriginModeResolvesThePathRelativeURLAgainstTheMetaURLAndSendsBothHeaders() async throws {
        let (_, transport) = try await fetch(try DeliveryFixtures.meta("origin"), try manifestAnswer())
        let request = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(request.url?.absoluteString, "https://api.example.invalid/projects/1/delivery/released/42/manifest")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Tarjim-Apikey"), DeliveryFixtures.apiKey)
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Tarjim-Api-Version"), "2026-07-29")
        XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), DeliveryFixtures.identity.userAgent)
        XCTAssertNil(request.value(forHTTPHeaderField: "Accept-Encoding"))
        XCTAssertNil(request.value(forHTTPHeaderField: "Range"))
        XCTAssertEqual(request.httpMethod, "GET")
    }

    /// Origin URLs are path-relative by contract. One with a scheme, a leading slash or a parent
    /// reference would send the key somewhere else: it is refused, not fetched.
    func testOriginModeNeverSendsTheKeyToAURLThatIsNotPathRelative() async throws {
        for bad in ["https://evil.example.invalid/released/42/manifest", "//evil.example.invalid/x", "/projects/2/delivery/released/42/manifest",
                    "released/../../../other/manifest", "evil.example.invalid:8443/x"] {
            var meta = try DeliveryFixtures.meta("origin")
            meta.manifestUrl = bad
            let (outcome, transport) = try await fetch(meta, try manifestAnswer())
            XCTAssertTrue(transport.requests.isEmpty, "a request was made for \(bad)")
            XCTAssertEqual(outcome, .refused, bad)
        }
    }

    // MARK: CDN mode

    /// Identity travels with the key only: a CDN request carries neither.
    func testCDNModeAppendsTheSignedQueryAndSendsNoTarjimOrIdentityHeader() async throws {
        let meta = try DeliveryFixtures.meta("cdn")
        let (_, transport) = try await fetch(meta, try manifestAnswer())
        let request = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(request.url?.absoluteString, meta.manifestUrl + "?" + (meta.signedQuery ?? ""))
        XCTAssertEqual(request.tarjimHeaders, [:])
        XCTAssertNil(request.value(forHTTPHeaderField: "User-Agent"))
        XCTAssertNil(request.value(forHTTPHeaderField: "Accept-Encoding"))
        XCTAssertNil(request.value(forHTTPHeaderField: "Range"))
        XCTAssertEqual(request.httpMethod, "GET")
    }

    func testCDNModeWithoutASignedQueryAppendsNothing() async throws {
        var meta = try DeliveryFixtures.meta("cdn")
        meta.signedQuery = nil
        let (_, transport) = try await fetch(meta, try manifestAnswer())
        XCTAssertEqual(try XCTUnwrap(transport.requests.first).url?.absoluteString, meta.manifestUrl)
        meta.signedQuery = ""
        let (_, again) = try await fetch(meta, try manifestAnswer())
        XCTAssertEqual(try XCTUnwrap(again.requests.first).url?.absoluteString, meta.manifestUrl)
    }

    /// Both URL parts are opaque and appended verbatim, so a part that would break the join is refused.
    func testCDNURLPartsThatCannotBeJoinedVerbatimAreRefused() async throws {
        let base = try DeliveryFixtures.meta("cdn")
        var withQuery = base; withQuery.manifestUrl += "?a=1"
        var withFragment = base; withFragment.manifestUrl += "#f"
        var hashInQuery = base; hashInQuery.signedQuery = "Policy=REDACTED#x"
        var relative = base; relative.manifestUrl = "releases/m/manifest.json"
        var spaced = base; spaced.signedQuery = "Policy=a b"
        for (label, meta) in [("query", withQuery), ("fragment", withFragment), ("hash in query", hashInQuery), ("relative", relative), ("space", spaced)] {
            let (outcome, transport) = try await fetch(meta, try manifestAnswer())
            XCTAssertTrue(transport.requests.isEmpty, label)
            XCTAssertEqual(outcome, .refused, label)
        }
    }

    // MARK: verification

    func testBytesHashingToMetaChecksumAreVerifiedAndDecoded() async throws {
        let bytes = try DeliveryFixtures.manifestBytes()
        let (outcome, _) = try await fetch(try DeliveryFixtures.meta("cdn"), try manifestAnswer(bytes))
        guard case let .verified(manifest, raw) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(raw, bytes)
        XCTAssertEqual(Set(manifest.bundles.keys), ["ns7", "ns12", "ns15", "b3"])
        XCTAssertEqual(manifest.bundles["b3"]?.type, "custom")
        XCTAssertEqual(manifest.slices["ns7"]?["ar"]?["strings"]?.hash.count, 64)
        XCTAssertEqual(manifest.schemaVersion, 1)
    }

    func testBytesNotHashingToMetaChecksumAreAMismatchAndNoManifest() async throws {
        var bytes = try DeliveryFixtures.manifestBytes()
        bytes[bytes.count - 2] ^= 0x01
        let (outcome, _) = try await fetch(try DeliveryFixtures.meta("cdn"), try manifestAnswer(bytes))
        XCTAssertEqual(outcome, .checksumMismatch)
    }

    func testBytesThatHashButDoNotDecodeAreUnreadable() async throws {
        let bytes = Data("not a manifest".utf8)
        var meta = try DeliveryFixtures.meta("cdn")
        meta.checksum = Fixtures.sha256Hex(bytes)
        let (outcome, _) = try await fetch(meta, try manifestAnswer(bytes))
        XCTAssertEqual(outcome, .unreadable)
    }

    // MARK: failures

    func testObjectErrorsMapToTheirOutcomes() async throws {
        let meta = try DeliveryFixtures.meta("cdn")
        let cases: [(FakeTransport.Answer, ManifestOutcome)] = [
            (try DeliveryFixtures.error("object-403-cdn-edge"), .unfetchable(status: 403, retryAfter: nil)),
            (try DeliveryFixtures.error("manifest-404-manifest-not-found"), .unfetchable(status: 404, retryAfter: nil)),
            (try DeliveryFixtures.error("manifest-503-manifest-unavailable"), .unfetchable(status: 503, retryAfter: 30)),
            (FakeTransport.Answer(status: 401), .unfetchable(status: 401, retryAfter: nil)),
            (FakeTransport.Answer(status: 400), .unfetchable(status: 400, retryAfter: nil)),
            (FakeTransport.Answer(status: 429, headers: ["Retry-After": "5"]), .throttled(retryAfter: 5)),
            (FakeTransport.Answer(status: 500), .serverError(retryAfter: nil)),
            (FakeTransport.Answer(status: 502, headers: ["Retry-After": "12"]), .serverError(retryAfter: 12)),
            (FakeTransport.Answer(status: 301, headers: ["Location": "https://other.example.invalid/"]), .serverError(retryAfter: nil)),
        ]
        for (answer, want) in cases {
            let (outcome, _) = try await fetch(meta, answer)
            XCTAssertEqual(outcome, want, "status \(answer.status)")
        }
    }

    func testNetworkFailure() async throws {
        let transport = FakeTransport()
        transport.enqueueFailure()
        let outcome = try await DeliveryFixtures.client(transport).fetchManifest(try DeliveryFixtures.meta("cdn"))
        XCTAssertEqual(outcome, .networkFailure)
    }
}
