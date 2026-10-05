import Foundation

/// `meta`, manifest and object requests over an injected transport. Pure: no state, no clock,
/// no file system. Every answer is a typed outcome; nothing here throws.
struct DeliveryClient: Sendable {
    let endpoint: DeliveryEndpoint
    let identity: ClientIdentity
    let transport: any Transport
    let apiVersion: String

    init(endpoint: DeliveryEndpoint, identity: ClientIdentity, transport: any Transport, apiVersion: String = "2026-07-29") {
        self.endpoint = endpoint
        self.identity = identity
        self.transport = transport
        self.apiVersion = apiVersion
    }

    func fetchMeta(ifNoneMatch etag: String?) async -> MetaOutcome {
        .unexpected(status: -1)
    }

    func fetchManifest(_ meta: Meta) async -> ManifestOutcome {
        .unfetchable(status: -1)
    }

    func fetchObject(_ meta: Meta, hash: String, fileType: String, expectedSize: Int?) async -> ObjectOutcome {
        .unfetchable(status: -1)
    }
}

enum Verifier {
    static func sha256Hex(_ data: Data) -> String {
        ""
    }

    static func matches(_ data: Data, sha256Hex expected: String) -> Bool {
        false
    }
}
