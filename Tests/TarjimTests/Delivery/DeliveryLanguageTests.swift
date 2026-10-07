import Foundation
import XCTest
@testable import Tarjim

/// The client asks for the language when it sends each keyed request, not once.
final class DeliveryLanguageTests: XCTestCase {
    private func language(of request: URLRequest) -> String? {
        request.value(forHTTPHeaderField: "User-Agent")?.split(separator: " ")
            .first { $0.hasPrefix("lang/") }.map { String($0.dropFirst(5)) }
    }

    func testOriginManifestAndObjectRequestsReadTheLanguageWhenSent() async throws {
        let selected = TestValue<String>("en")
        let transport = FakeTransport()
        let client = DeliveryClient(endpoint: try DeliveryFixtures.endpoint(), identity: DeliveryFixtures.identity,
                                    transport: transport, language: { selected.value })
        let meta = try DeliveryFixtures.meta("origin")
        transport.enqueue(FakeTransport.Answer(status: 200, headers: ["Content-Type": "application/json; charset=utf-8"],
                                               body: try DeliveryFixtures.manifestBytes()))
        _ = await client.fetchManifest(meta)
        selected.value = "ar"
        let object = try XCTUnwrap(DeliveryFixtures.objects().first)
        transport.enqueue(FakeTransport.Answer(status: 200, body: try Fixtures.data("release-1/objects/\(object.hash).\(object.fileType)")))
        _ = await client.fetchObject(meta, hash: object.hash, fileType: object.fileType, expectedSize: object.size)
        XCTAssertEqual(transport.requests.count, 2)
        XCTAssertEqual(transport.requests.map(language(of:)), ["en", "ar"])
    }
}
