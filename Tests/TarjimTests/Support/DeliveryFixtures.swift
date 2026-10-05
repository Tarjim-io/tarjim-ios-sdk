import Foundation
import XCTest
@testable import Tarjim

/// One endpoint, one identity and the recorded fixtures, shared by the delivery tests.
enum DeliveryFixtures {
    static let host = URL(string: "https://api.example.invalid")!
    static let projectId = 1
    /// Opaque to the client; deliberately not in the server's key format so the leak scan never
    /// mistakes it for a real one.
    static let apiKey = "test-key-not-a-real-key-0123456789"
    static let identity = ClientIdentity(sdkVersion: "0.1.0", appVersion: "2.3.1", osVersion: "17.4", language: "ar", installIdentifier: nil)

    static func endpoint() throws -> DeliveryEndpoint {
        try DeliveryEndpoint(host: host, projectId: projectId, apiKey: apiKey)
    }

    static func client(_ transport: FakeTransport, identity: ClientIdentity = identity) throws -> DeliveryClient {
        DeliveryClient(endpoint: try endpoint(), identity: identity, transport: transport)
    }

    static func metaEnvelope(_ mode: String) throws -> ResponseEnvelope {
        try Fixtures.envelope("release-1/meta.\(mode).json")
    }

    /// The fixture's `meta` body decoded directly, so manifest and object tests do not depend on
    /// `fetchMeta`.
    static func meta(_ mode: String) throws -> Meta {
        let body = try XCTUnwrap(metaEnvelope(mode).body)
        return try JSONDecoder().decode(Meta.self, from: Data(body.utf8))
    }

    static func manifestBytes() throws -> Data {
        try Fixtures.data("release-1/manifest.json")
    }

    static func manifest() throws -> Manifest {
        try JSONDecoder().decode(Manifest.self, from: manifestBytes())
    }

    static func error(_ name: String) throws -> FakeTransport.Answer {
        FakeTransport.Answer(try Fixtures.envelope("errors/\(name).json"))
    }

    /// Every (hash, fileType, size) the release manifest lists, each once.
    static func objects() throws -> [(hash: String, fileType: String, size: Int)] {
        var seen = Set<String>()
        var out: [(String, String, Int)] = []
        for byLocale in try manifest().slices.values {
            for byFileType in byLocale.values {
                for (fileType, entry) in byFileType where seen.insert("\(entry.hash).\(fileType)").inserted {
                    out.append((entry.hash, fileType, entry.size))
                }
            }
        }
        return out.sorted { "\($0.0).\($0.1)" < "\($1.0).\($1.1)" }
    }
}

extension URLRequest {
    var tarjimHeaders: [String: String] {
        (allHTTPHeaderFields ?? [:]).filter { $0.key.lowercased().hasPrefix("x-tarjim-") }
    }
}
