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
