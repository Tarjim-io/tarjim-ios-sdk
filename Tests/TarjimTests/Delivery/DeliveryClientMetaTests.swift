import Foundation
import XCTest
@testable import Tarjim

final class DeliveryClientMetaTests: XCTestCase {
    private func fetch(_ answer: FakeTransport.Answer, etag: String? = nil) async throws -> (MetaOutcome, URLRequest) {
        let transport = FakeTransport()
        transport.enqueue(answer)
        let outcome = try await DeliveryFixtures.client(transport).fetchMeta(ifNoneMatch: etag)
        let request = try XCTUnwrap(transport.requests.first, "no request was made")
        return (outcome, request)
    }

    // MARK: the request

    func testRequestIsGetOnTheMetaURLWithKeyVersionAndUserAgentHeadersAndNoQuery() async throws {
        let (_, request) = try await fetch(FakeTransport.Answer(try DeliveryFixtures.metaEnvelope("cdn")))
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.url, try DeliveryFixtures.endpoint().metaURL)
        XCTAssertNil(request.url?.query, "the key never travels in a query string")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Tarjim-Apikey"), DeliveryFixtures.apiKey)
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Tarjim-Api-Version"), "2026-07-29")
        XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), DeliveryFixtures.identity.userAgent)
        XCTAssertNil(request.value(forHTTPHeaderField: "If-None-Match"))
    }

    func testIfNoneMatchIsSentExactlyWhenAnETagIsGiven() async throws {
        let (_, request) = try await fetch(FakeTransport.Answer(try Fixtures.envelope("errors/meta-304.json")), etag: "\"m17-abc-p1800\"")
        XCTAssertEqual(request.value(forHTTPHeaderField: "If-None-Match"), "\"m17-abc-p1800\"")
    }

    func testNeverSetsAcceptEncoding() async throws {
        let (_, request) = try await fetch(FakeTransport.Answer(try DeliveryFixtures.metaEnvelope("origin")))
        XCTAssertNil(request.value(forHTTPHeaderField: "Accept-Encoding"))
    }

    // MARK: 200 and 304

    func testCDNMetaDecodesWithETagAndRawBytes() async throws {
        let envelope = try DeliveryFixtures.metaEnvelope("cdn")
        let (outcome, _) = try await fetch(FakeTransport.Answer(envelope))
        guard case let .received(meta, etag, raw) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(meta.checksum, Fixtures.sha256Hex(try DeliveryFixtures.manifestBytes()))
        XCTAssertEqual(meta.authenticated, false)
        XCTAssertNotNil(meta.signedQuery)
        XCTAssertEqual(meta.schemaVersion, 1)
        XCTAssertEqual(meta.pollAfter, 1800)
        XCTAssertEqual(meta.releaseId, 42)
        XCTAssertEqual(etag, envelope.header("ETag"))
        XCTAssertEqual(raw, Data(try XCTUnwrap(envelope.body).utf8))
    }

    func testOriginMetaDecodesAsAuthenticatedWithoutSignedQuery() async throws {
        let (outcome, _) = try await fetch(FakeTransport.Answer(try DeliveryFixtures.metaEnvelope("origin")))
        guard case let .received(meta, _, _) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(meta.authenticated, true)
        XCTAssertNil(meta.signedQuery)
        XCTAssertEqual(meta.manifestUrl, "released/42/manifest")
    }

    func testUnknownFieldsAreIgnoredAndAbsentAuthenticatedMeansCDNMode() async throws {
        var body = try JSONSerialization.jsonObject(with: Data(try XCTUnwrap(DeliveryFixtures.metaEnvelope("cdn").body).utf8)) as! [String: Any]
        body["authenticated"] = nil
        body["somethingNew"] = ["nested": true]
        let (outcome, _) = try await fetch(.json(200, body))
        guard case let .received(meta, _, _) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(meta.authenticated, false)
    }

    func testNotModified() async throws {
        let (outcome, _) = try await fetch(FakeTransport.Answer(try Fixtures.envelope("errors/meta-304.json")))
        XCTAssertEqual(outcome, .notModified)
    }

    func testUndecodable200IsUnreadable() async throws {
        let (notJSON, _) = try await fetch(FakeTransport.Answer(status: 200, headers: ["Content-Type": "text/html"], body: Data("<html>".utf8)))
        XCTAssertEqual(notJSON, .unreadable)
        let (noChecksum, _) = try await fetch(.json(200, ["schemaVersion": 1, "manifestUrl": "x", "slicesBaseUrl": "y", "pollAfter": 60]))
        XCTAssertEqual(noChecksum, .unreadable)
    }

    // MARK: every error row of the status table, from the fixtures

    func testEveryRecordedErrorAnswerMapsToItsOutcome() async throws {
        let expected: [String: MetaOutcome] = [
            "meta-400-validation": .configurationError(code: "validation", pollAfter: nil),
            "meta-401-unauthorized": .configurationError(code: "unauthorized", pollAfter: nil),
            "meta-403-apikey-project-mismatch": .configurationError(code: "delivery.apikey_project_mismatch", pollAfter: nil),
            "meta-403-forbidden": .configurationError(code: "forbidden", pollAfter: nil),
            "meta-404-track-not-found": .configurationError(code: "delivery.track_not_found", pollAfter: 1800),
            "meta-404-stage-not-found": .configurationError(code: "delivery.stage_not_found", pollAfter: 1800),
            "meta-404-stage-unreleased": .unreleased(pollAfter: 900),
            "meta-404-not-found": .configurationError(code: "not-found", pollAfter: nil),
            "meta-429-too-many-requests": .throttled(retryAfter: 60),
            "meta-429-invalid-key-limiter": .throttled(retryAfter: nil),
            "meta-500-cdn-signing-failed": .serverError(retryAfter: nil),
            "meta-502-upstream-error": .serverError(retryAfter: nil),
            "meta-503-disabled": .serverError(retryAfter: nil),
            "meta-503-cdn-edge": .serverError(retryAfter: nil),
        ]
        for (name, want) in expected {
            let (outcome, _) = try await fetch(try DeliveryFixtures.error(name))
            XCTAssertEqual(outcome, want, name)
        }
    }

    func testUnknown404CodeIsConfigurationErrorWithItsPollAfterNeverLatest() async throws {
        let (outcome, _) = try await fetch(.json(404, ["type": "https://api.example.invalid/problems/delivery.something_new", "title": "Not Found",
                                                       "status": 404, "code": "delivery.something_new", "pollAfter": 120],
                                                 headers: ["Content-Type": "application/problem+json; charset=utf-8"]))
        XCTAssertEqual(outcome, .configurationError(code: "delivery.something_new", pollAfter: 120))
    }

    func testUnreadable4xxBodyIsConfigurationErrorWithUnknownCode() async throws {
        let (edge404, _) = try await fetch(FakeTransport.Answer(status: 404, headers: ["Content-Type": "text/html"], body: Data("<html>gone".utf8)))
        XCTAssertEqual(edge404, .configurationError(code: "unknown", pollAfter: nil))
    }

    /// Only 400, 401, 403 and 404 are the configuration class; anything else outside the table is
    /// backed off like a server error.
    func testStatusesOutsideTheTableBackOff() async throws {
        for status in [418, 204, 599] {
            let (outcome, _) = try await fetch(FakeTransport.Answer(status: status))
            XCTAssertEqual(outcome, .serverError(retryAfter: nil), "\(status)")
        }
    }

    /// Redirects are never followed. On `meta` a 3xx means the configured host has moved: that is
    /// a misconfiguration to report once, not something to back off from in silence for ever.
    func testARedirectOnMetaIsAReportedConfigurationError() async throws {
        for status in [301, 302, 307, 308] {
            let (outcome, _) = try await fetch(FakeTransport.Answer(status: status, headers: ["Location": "https://other.example.invalid/"]))
            XCTAssertEqual(outcome, .configurationError(code: "redirect", pollAfter: nil), "\(status)")
        }
    }

    func testRetryAfterIsTrimmedAndNeverNegative() async throws {
        let (padded, _) = try await fetch(FakeTransport.Answer(status: 503, headers: ["Retry-After": " 7 "]))
        XCTAssertEqual(padded, .serverError(retryAfter: 7))
        let (negative, _) = try await fetch(FakeTransport.Answer(status: 503, headers: ["Retry-After": "-5"]))
        XCTAssertEqual(negative, .serverError(retryAfter: nil))
    }

    /// An older server answers a cold key with these codes; they are the same normal state, not a
    /// misconfiguration to report.
    func testOlderUnreleasedCodesAreUnreleasedToo() async throws {
        for code in ["delivery.track_unreleased", "delivery.not_published"] {
            let (outcome, _) = try await fetch(.json(404, ["status": 404, "code": code, "pollAfter": 60],
                                                     headers: ["Content-Type": "application/problem+json; charset=utf-8"]))
            XCTAssertEqual(outcome, .unreleased(pollAfter: 60), code)
        }
    }

    func testAProblemBodyWithAnOddPollAfterStillYieldsItsCode() async throws {
        let (outcome, _) = try await fetch(.json(404, ["status": 404, "code": "delivery.stage_unreleased", "pollAfter": "900"],
                                                 headers: ["Content-Type": "application/problem+json; charset=utf-8"]))
        XCTAssertEqual(outcome, .unreleased(pollAfter: nil))
    }

    func testAuthenticatedThatIsNotABoolIsUnreadable() async throws {
        var body = try JSONSerialization.jsonObject(with: Data(try XCTUnwrap(DeliveryFixtures.metaEnvelope("origin").body).utf8)) as! [String: Any]
        body["authenticated"] = "true"
        let (outcome, _) = try await fetch(.json(200, body))
        XCTAssertEqual(outcome, .unreadable, "fail closed rather than guess the mode")
    }

    func testRetryAfterIsReadAsSecondsOnly() async throws {
        let (seconds, _) = try await fetch(FakeTransport.Answer(status: 503, headers: ["Retry-After": "30"]))
        XCTAssertEqual(seconds, .serverError(retryAfter: 30))
        let (date, _) = try await fetch(FakeTransport.Answer(status: 503, headers: ["Retry-After": "Wed, 21 Oct 2026 07:28:00 GMT"]))
        XCTAssertEqual(date, .serverError(retryAfter: nil))
        let (throttled, _) = try await fetch(FakeTransport.Answer(status: 429, headers: ["Retry-After": "7"]))
        XCTAssertEqual(throttled, .throttled(retryAfter: 7))
    }

    func testNetworkFailure() async throws {
        let transport = FakeTransport()
        transport.enqueueFailure()
        let outcome = try await DeliveryFixtures.client(transport).fetchMeta(ifNoneMatch: nil)
        XCTAssertEqual(outcome, .networkFailure)
    }
}
