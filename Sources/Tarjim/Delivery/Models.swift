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

    private enum CodingKeys: String, CodingKey { case schemaVersion, baseLocale, bundles, slices }

    /// A file type this SDK does not know may carry another entry shape; it is dropped so the
    /// rest of the release still installs.
    private struct LenientEntry: Decodable {
        let entry: SliceEntry?
        init(from decoder: Decoder) throws {
            entry = try? SliceEntry(from: decoder)
        }
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decode(Int.self, forKey: .schemaVersion)
        baseLocale = try c.decodeIfPresent(String.self, forKey: .baseLocale)
        bundles = try c.decode([String: BundleEntry].self, forKey: .bundles)
        let raw = try c.decode([String: [String: [String: LenientEntry]]].self, forKey: .slices)
        slices = raw.mapValues { $0.mapValues { $0.compactMapValues(\.entry) } }
    }
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
    /// Advisory; a producer may omit it.
    var transferSize: Int?
}

extension Meta: CustomStringConvertible, CustomDebugStringConvertible {
    var description: String {
        "Meta(checksum: \(checksum), releaseId: \(releaseId.map(String.init) ?? "nil"), mode: \(authenticated ? "origin" : "cdn"))"
    }

    var debugDescription: String { description }
}

extension Meta: CustomReflectable {
    var customMirror: Mirror {
        Mirror(self, children: ["checksum": checksum, "schemaVersion": schemaVersion, "authenticated": authenticated,
                                "releaseId": releaseId as Any, "pollAfter": pollAfter], displayStyle: .struct)
    }
}
