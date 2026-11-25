import Foundation
import XCTest
@testable import Tarjim

/// What travels where: the identity query on `meta` only, read when each request is sent; manifest and object
/// requests carry the SDK's User-Agent and nothing about the app.
final class DeliveryLanguageTests: XCTestCase {
    func testEachMetaRequestReadsTheLanguageWhenSent() async throws {
        let selected = TestValue<String>("en")
        let transport = FakeTransport()
        let client = DeliveryClient(endpoint: try DeliveryFixtures.endpoint(), identity: DeliveryFixtures.identity,
                                    transport: transport, language: { selected.value })
        transport.enqueue(FakeTransport.Answer(try DeliveryFixtures.metaEnvelope("cdn")))
        _ = await client.fetchMeta(ifNoneMatch: nil)
        selected.value = "ar"
        transport.enqueue(FakeTransport.Answer(try DeliveryFixtures.metaEnvelope("cdn")))
        _ = await client.fetchMeta(ifNoneMatch: nil)
        XCTAssertEqual(transport.requests.map { MetaRequest.query($0)["language"] }, ["en", "ar"])
    }

    func testOriginManifestAndObjectRequestsCarryNoIdentityQuery() async throws {
        let transport = FakeTransport()
        let client = DeliveryClient(endpoint: try DeliveryFixtures.endpoint(), identity: DeliveryFixtures.identity, transport: transport)
        let meta = try DeliveryFixtures.meta("origin")
        transport.enqueue(FakeTransport.Answer(status: 200, headers: ["Content-Type": "application/json; charset=utf-8"],
                                               body: try DeliveryFixtures.manifestBytes()))
        _ = await client.fetchManifest(meta)
        let object = try XCTUnwrap(DeliveryFixtures.objects().first)
        transport.enqueue(FakeTransport.Answer(status: 200, body: try Fixtures.data("release-1/objects/\(object.hash).\(object.fileType)")))
        _ = await client.fetchObject(meta, hash: object.hash, fileType: object.fileType, expectedSize: object.size)
        XCTAssertEqual(transport.requests.count, 2)
        for request in transport.requests {
            XCTAssertNotNil(request.value(forHTTPHeaderField: "X-Tarjim-Apikey"), "an origin request")
            XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), "Tarjim-iOS/0.1.0")
            XCTAssertNil(request.url?.query, "\(request.url!)")
            XCTAssertNil(request.value(forHTTPHeaderField: "X-Tarjim-App-Version"))
        }
    }
}
