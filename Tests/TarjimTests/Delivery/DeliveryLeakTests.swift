import Foundation
import XCTest
@testable import Tarjim

/// The key and the signed query must never reach a log line or a report. The cheapest way they
/// would is a value being interpolated into a string, so every type that holds one must redact
/// itself in both string forms.
final class DeliveryLeakTests: XCTestCase {
    private func descriptions(_ value: Any) -> [String] {
        [String(describing: value), String(reflecting: value)]
    }

    func testEndpointAndClientNeverPrintTheKey() throws {
        let endpoint = try DeliveryFixtures.endpoint()
        let client = DeliveryClient(endpoint: endpoint, identity: DeliveryFixtures.identity, transport: FakeTransport())
        for text in descriptions(endpoint) + descriptions(client) {
            XCTAssertFalse(text.contains(DeliveryFixtures.apiKey), text)
        }
        XCTAssertTrue(String(describing: endpoint).contains("api.example.invalid"), "the host is fine to print")
    }

    func testMetaAndMetaOutcomeNeverPrintTheSignedQuery() throws {
        let meta = try DeliveryFixtures.meta("cdn")
        let signedQuery = try XCTUnwrap(meta.signedQuery)
        let outcome = MetaOutcome.changed(meta, etag: "\"e\"", raw: Data(try XCTUnwrap(DeliveryFixtures.metaEnvelope("cdn").body).utf8))
        for text in descriptions(meta) + descriptions(outcome) {
            XCTAssertFalse(text.contains(signedQuery), text)
            XCTAssertFalse(text.contains("Policy=REDACTED"), text)
        }
        XCTAssertTrue(String(describing: meta).contains(meta.checksum.prefix(8)), "the checksum is fine to print")
    }

    func testFailureOutcomesCarryNoSecretAtAll() async throws {
        let transport = FakeTransport()
        for name in ["meta-401-unauthorized", "meta-404-stage-unreleased", "meta-429-too-many-requests", "meta-503-disabled"] {
            transport.enqueue(try DeliveryFixtures.error(name))
        }
        let client = try DeliveryFixtures.client(transport)
        for _ in 0..<4 {
            let outcome = await client.fetchMeta(ifNoneMatch: nil)
            for text in descriptions(outcome) {
                XCTAssertFalse(text.contains(DeliveryFixtures.apiKey), text)
            }
        }
    }
}

final class URLSessionTransportTests: XCTestCase {
    func testSessionHasNoCacheNoCookiesAndSetsNoAcceptEncoding() {
        let configuration = URLSessionTransport.makeConfiguration()
        XCTAssertNil(configuration.urlCache)
        XCTAssertEqual(configuration.requestCachePolicy, .reloadIgnoringLocalCacheData)
        XCTAssertNil(configuration.httpCookieStorage)
        XCTAssertFalse(configuration.httpShouldSetCookies)
        let additional = (configuration.httpAdditionalHeaders ?? [:]).keys.compactMap { $0 as? String }.map { $0.lowercased() }
        XCTAssertFalse(additional.contains("accept-encoding"))
    }
}
