import Foundation
import XCTest
@testable import Tarjim

final class DeliveryClientObjectTests: XCTestCase {
    private let strings = "strings"

    private func fetch(_ meta: Meta, hash: String, fileType: String, expectedSize: Int?, _ answer: FakeTransport.Answer?) async throws -> (ObjectOutcome, FakeTransport) {
        let transport = FakeTransport()
        if let answer { transport.enqueue(answer) }
        let outcome = try await DeliveryFixtures.client(transport).fetchObject(meta, hash: hash, fileType: fileType, expectedSize: expectedSize)
        return (outcome, transport)
    }

    private func firstObject() throws -> (hash: String, fileType: String, size: Int, bytes: Data) {
        let object = try XCTUnwrap(DeliveryFixtures.objects().first)
        return (object.hash, object.fileType, object.size, try Fixtures.data("release-1/objects/\(object.hash).\(object.fileType)"))
    }

    // MARK: URLs and headers

    func testOriginModeURLIsSlicesBaseUrlPlusHashDotFileTypeWithBothHeaders() async throws {
        let object = try firstObject()
        let (_, transport) = try await fetch(try DeliveryFixtures.meta("origin"), hash: object.hash, fileType: object.fileType, expectedSize: object.size,
                                             FakeTransport.Answer(status: 200, body: object.bytes))
        let request = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(request.url?.absoluteString, "https://api.example.invalid/projects/1/delivery/released/slices/\(object.hash).\(object.fileType)")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Tarjim-Apikey"), DeliveryFixtures.apiKey)
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Tarjim-Api-Version"), "2026-07-29")
        XCTAssertNil(request.value(forHTTPHeaderField: "Accept-Encoding"))
    }

    func testCDNModeURLCarriesTheSignedQueryAndNoTarjimHeader() async throws {
        let meta = try DeliveryFixtures.meta("cdn")
        let object = try firstObject()
        let (_, transport) = try await fetch(meta, hash: object.hash, fileType: object.fileType, expectedSize: object.size,
                                             FakeTransport.Answer(status: 200, body: object.bytes))
        let request = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(request.url?.absoluteString, meta.slicesBaseUrl + object.hash + "." + object.fileType + "?" + (meta.signedQuery ?? ""))
        XCTAssertEqual(request.tarjimHeaders, [:])
        XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), DeliveryFixtures.identity.userAgent)
    }

    /// `hash` and `fileType` come from a downloaded manifest; only a 64-hex hash and a plain
    /// lower-case file type may become part of a URL.
    func testAManifestEntryThatIsNotAHashAndAFileTypeIsNeverRequested() async throws {
        let meta = try DeliveryFixtures.meta("origin")
        for (hash, fileType) in [("../../meta", strings), (String(repeating: "a", count: 64), "strings?x=1"), ("ABCDEF", strings),
                                 (String(repeating: "a", count: 64), "../meta"), (String(repeating: "A", count: 64), strings)] {
            let (outcome, transport) = try await fetch(meta, hash: hash, fileType: fileType, expectedSize: nil, FakeTransport.Answer(status: 200))
            XCTAssertTrue(transport.requests.isEmpty, "\(hash).\(fileType) was requested")
            if case .verified = outcome { XCTFail("verified \(hash).\(fileType)") }
        }
    }

    // MARK: verification

    func testEveryObjectOfTheRecordedReleaseVerifies() async throws {
        let meta = try DeliveryFixtures.meta("cdn")
        let objects = try DeliveryFixtures.objects()
        XCTAssertGreaterThanOrEqual(objects.count, 18)
        for object in objects {
            let bytes = try Fixtures.data("release-1/objects/\(object.hash).\(object.fileType)")
            let (outcome, _) = try await fetch(meta, hash: object.hash, fileType: object.fileType, expectedSize: object.size, FakeTransport.Answer(status: 200, body: bytes))
            XCTAssertEqual(outcome, .verified(bytes), "\(object.hash).\(object.fileType)")
        }
    }

    func testBytesNotHashingToTheEntryAreDiscarded() async throws {
        let object = try firstObject()
        var bytes = object.bytes
        bytes[0] ^= 0x01
        let (outcome, _) = try await fetch(try DeliveryFixtures.meta("cdn"), hash: object.hash, fileType: object.fileType, expectedSize: object.size,
                                           FakeTransport.Answer(status: 200, body: bytes))
        XCTAssertEqual(outcome, .hashMismatch)
    }

    func testMoreBytesThanSizeAreRefusedBeforeHashing() async throws {
        let object = try firstObject()
        let (outcome, _) = try await fetch(try DeliveryFixtures.meta("cdn"), hash: object.hash, fileType: object.fileType, expectedSize: object.size - 1,
                                           FakeTransport.Answer(status: 200, body: object.bytes))
        XCTAssertEqual(outcome, .tooLarge)
    }

    func testFewerBytesThanSizeFailTheHash() async throws {
        let object = try firstObject()
        let (outcome, _) = try await fetch(try DeliveryFixtures.meta("cdn"), hash: object.hash, fileType: object.fileType, expectedSize: object.size,
                                           FakeTransport.Answer(status: 200, body: object.bytes.dropLast()))
        XCTAssertEqual(outcome, .hashMismatch)
    }

    func testWithoutASizeTheHashAloneDecides() async throws {
        let object = try firstObject()
        let (outcome, _) = try await fetch(try DeliveryFixtures.meta("cdn"), hash: object.hash, fileType: object.fileType, expectedSize: nil,
                                           FakeTransport.Answer(status: 200, body: object.bytes))
        XCTAssertEqual(outcome, .verified(object.bytes))
    }

    // MARK: failures

    func testObjectErrorsMapToTheirOutcomes() async throws {
        let meta = try DeliveryFixtures.meta("cdn")
        let object = try firstObject()
        let cases: [(FakeTransport.Answer, ObjectOutcome)] = [
            (try DeliveryFixtures.error("object-403-cdn-edge"), .unfetchable(status: 403)),
            (try DeliveryFixtures.error("object-404-slice-not-found"), .unfetchable(status: 404)),
            (FakeTransport.Answer(status: 503, headers: ["Retry-After": "30"]), .unfetchable(status: 503)),
            (FakeTransport.Answer(status: 429, headers: ["Retry-After": "9"]), .throttled(retryAfter: 9)),
            (FakeTransport.Answer(status: 500), .serverError(retryAfter: nil)),
        ]
        for (answer, want) in cases {
            let (outcome, _) = try await fetch(meta, hash: object.hash, fileType: object.fileType, expectedSize: object.size, answer)
            XCTAssertEqual(outcome, want, "status \(answer.status)")
        }
        let transport = FakeTransport()
        transport.enqueueFailure()
        let offline = try await DeliveryFixtures.client(transport).fetchObject(meta, hash: object.hash, fileType: object.fileType, expectedSize: nil)
        XCTAssertEqual(offline, .networkFailure)
    }

    // MARK: the key stays home

    func testAcrossAWholeCDNCycleNoRequestLeavesTheHostWithTheKey() async throws {
        let transport = FakeTransport()
        transport.enqueue(FakeTransport.Answer(try DeliveryFixtures.metaEnvelope("cdn")))
        transport.enqueue(FakeTransport.Answer(status: 200, body: try DeliveryFixtures.manifestBytes()))
        let object = try firstObject()
        transport.enqueue(FakeTransport.Answer(status: 200, body: object.bytes))
        let client = try DeliveryFixtures.client(transport)
        guard case let .changed(meta, _, _) = await client.fetchMeta(ifNoneMatch: nil) else { return XCTFail("meta") }
        _ = await client.fetchManifest(meta)
        _ = await client.fetchObject(meta, hash: object.hash, fileType: object.fileType, expectedSize: object.size)
        XCTAssertEqual(transport.requests.count, 3)
        for request in transport.requests {
            let host = request.url?.host ?? ""
            let carriesKey = (request.allHTTPHeaderFields ?? [:]).values.contains { $0.contains(DeliveryFixtures.apiKey) }
                || (request.url?.absoluteString.contains(DeliveryFixtures.apiKey) ?? false)
            XCTAssertEqual(carriesKey, host == DeliveryFixtures.host.host, "\(request.url?.absoluteString ?? "")")
        }
    }
}
