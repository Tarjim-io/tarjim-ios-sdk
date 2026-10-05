import Foundation
import XCTest
@testable import Tarjim

/// The manifest only ever gains fields and file types. A reader that refuses what it does not know
/// would freeze every installed app on its held release the day the server adds something.
final class DeliveryDecodingTests: XCTestCase {
    private struct NotVerified: Error {}

    private func verified(_ object: [String: Any]) async throws -> Manifest {
        let bytes = try JSONSerialization.data(withJSONObject: object)
        var meta = try DeliveryFixtures.meta("cdn")
        meta.checksum = Fixtures.sha256Hex(bytes)
        let transport = FakeTransport()
        transport.enqueue(FakeTransport.Answer(status: 200, body: bytes))
        let outcome = try await DeliveryFixtures.client(transport).fetchManifest(meta)
        guard case let .verified(manifest, _) = outcome else {
            XCTFail("\(outcome)")
            throw NotVerified()
        }
        return manifest
    }

    private func baseline() throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: DeliveryFixtures.manifestBytes()) as? [String: Any])
    }

    func testUnknownFieldsAtEveryLevelAreIgnored() async throws {
        var object = try baseline()
        object["generation"] = 12
        object["signatures"] = ["ed25519": "abc"]
        var bundles = object["bundles"] as! [String: Any]
        var ns7 = bundles["ns7"] as! [String: Any]
        ns7["colour"] = "blue"
        bundles["ns7"] = ns7
        object["bundles"] = bundles
        var slices = object["slices"] as! [String: Any]
        var ns7Slices = slices["ns7"] as! [String: Any]
        var en = ns7Slices["en"] as! [String: Any]
        var strings = en["strings"] as! [String: Any]
        strings["etag"] = "\"x\""
        en["strings"] = strings
        ns7Slices["en"] = en
        slices["ns7"] = ns7Slices
        object["slices"] = slices
        let manifest = try await verified(object)
        XCTAssertEqual(manifest.bundles["ns7"]?.name, "default")
        XCTAssertEqual(manifest.slices["ns7"]?["en"]?["strings"]?.size, (strings["size"] as! Int))
    }

    func testAFileTypeWithAnotherEntryShapeIsDroppedNotFatal() async throws {
        var object = try baseline()
        var slices = object["slices"] as! [String: Any]
        var ns7Slices = slices["ns7"] as! [String: Any]
        var en = ns7Slices["en"] as! [String: Any]
        en["sqlite"] = ["url": "https://cdn.example.invalid/x.sqlite", "bytes": 10]
        en["strings-v2"] = "not even an object"
        ns7Slices["en"] = en
        slices["ns7"] = ns7Slices
        object["slices"] = slices
        let manifest = try await verified(object)
        let entries = try XCTUnwrap(manifest.slices["ns7"]?["en"])
        XCTAssertEqual(Set(entries.keys), ["json", "strings", "stringsdict"], "the unreadable file types are absent, the readable ones kept")
    }

    func testTransferSizeIsOptional() async throws {
        var object = try baseline()
        var slices = object["slices"] as! [String: Any]
        var ns7Slices = slices["ns7"] as! [String: Any]
        var en = ns7Slices["en"] as! [String: Any]
        var strings = en["strings"] as! [String: Any]
        strings["transferSize"] = nil
        en["strings"] = strings
        ns7Slices["en"] = en
        slices["ns7"] = ns7Slices
        object["slices"] = slices
        let manifest = try await verified(object)
        XCTAssertNil(manifest.slices["ns7"]?["en"]?["strings"]?.transferSize)
        XCTAssertEqual(manifest.slices["ns7"]?["en"]?["strings"]?.hash.count, 64)
    }

    func testABundleEntryWithoutATypeOrNameIsFatalBecauseItCannotBeAddressed() async throws {
        var object = try baseline()
        var bundles = object["bundles"] as! [String: Any]
        bundles["ns7"] = ["colour": "blue"]
        object["bundles"] = bundles
        let bytes = try JSONSerialization.data(withJSONObject: object)
        var meta = try DeliveryFixtures.meta("cdn")
        meta.checksum = Fixtures.sha256Hex(bytes)
        let transport = FakeTransport()
        transport.enqueue(FakeTransport.Answer(status: 200, body: bytes))
        let outcome = try await DeliveryFixtures.client(transport).fetchManifest(meta)
        XCTAssertEqual(outcome, .unreadable)
    }
}
