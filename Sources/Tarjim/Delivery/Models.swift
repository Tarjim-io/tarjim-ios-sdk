import Foundation

/// The fields of a `meta` answer the SDK reads. Everything else in the body is ignored.
struct Meta: Decodable, Sendable, Equatable {
    var checksum: String
    var schemaVersion: Int
    var manifestUrl: String
    var slicesBaseUrl: String
    /// `true` means origin mode: the SDK's own headers go to the manifest and object URLs.
    /// Anything else means CDN mode: no `X-Tarjim-*` header, `signedQuery` appended.
    var authenticated: Bool
    var signedQuery: String?
    var releaseId: Int?
    var pollAfter: Int
    var track: String?
    var stage: String?
}

extension Meta {
    private enum CodingKeys: String, CodingKey {
        case checksum, schemaVersion, manifestUrl, slicesBaseUrl, authenticated, signedQuery, releaseId, pollAfter, track, stage
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        checksum = try c.decode(String.self, forKey: .checksum)
        schemaVersion = try c.decode(Int.self, forKey: .schemaVersion)
        manifestUrl = try c.decode(String.self, forKey: .manifestUrl)
        slicesBaseUrl = try c.decode(String.self, forKey: .slicesBaseUrl)
        // Absent means CDN mode, the one that never attaches the key.
        authenticated = try c.decodeIfPresent(Bool.self, forKey: .authenticated) ?? false
        signedQuery = try c.decodeIfPresent(String.self, forKey: .signedQuery)
        releaseId = try c.decodeIfPresent(Int.self, forKey: .releaseId)
        pollAfter = try c.decode(Int.self, forKey: .pollAfter)
        track = try c.decodeIfPresent(String.self, forKey: .track)
        stage = try c.decodeIfPresent(String.self, forKey: .stage)
    }
}

struct Manifest: Decodable, Sendable, Equatable {
    var schemaVersion: Int
    var baseLocale: String?
    var bundles: [String: BundleEntry]
    var slices: [String: [String: [String: SliceEntry]]]
}

struct BundleEntry: Decodable, Sendable, Equatable {
    var type: String
    var name: String
    var layout: String?
    var namespaces: [String]?
}

struct SliceEntry: Decodable, Sendable, Equatable {
    var hash: String
    var size: Int
    var transferSize: Int
}
