import Foundation
import XCTest
@testable import Tarjim

/// A delivery server answering by URL: `meta` from a queue (the last answer repeats), the manifest and the
/// objects of whatever releases it was given, by hash. Object answers can be overridden per hash.
final class DeliveryServer: Transport, @unchecked Sendable {
    private let lock = NSLock()
    private var metaAnswers: [FakeTransport.Answer] = []
    private var publishedMeta: FakeTransport.Answer?
    private var manifests: [String: Data] = [:]        // checksum → bytes
    private var objects: [String: Data] = [:]          // "<hash>.<type>" → bytes
    private var objectOverrides: [String: [FakeTransport.Answer]] = [:]
    private var offline = false
    private var manifestOverrides: [FakeTransport.Answer] = []
    /// Runs (synchronously, on the request's thread) before each object answer — a hook for "meanwhile" writes.
    var onObjectRequest: (@Sendable () -> Void)? {
        get { lock.withLock { objectHook } }
        set { lock.withLock { objectHook = newValue } }
    }
    private var objectHook: (@Sendable () -> Void)?
    private var recorded: [URLRequest] = []

    var requests: [URLRequest] { lock.withLock { recorded } }
    var metaRequests: [URLRequest] { requests.filter { $0.url!.path.hasSuffix("/delivery/meta") } }
    var manifestRequests: [URLRequest] { requests.filter { $0.url!.lastPathComponent == "manifest.json" } }
    var objectRequests: [URLRequest] { requests.filter { Release.isObject($0.url!) } }

    /// Serves `release`: its manifest, its objects, and (unless `meta` is false) a 200 `meta` naming it.
    func publish(_ release: Release, meta: Bool = true) {
        lock.withLock {
            manifests[release.checksum] = release.manifest
            objects.merge(release.objects) { _, new in new }
            if meta {
                publishedMeta = release.metaAnswer()
                metaAnswers = [release.metaAnswer()]
            }
        }
    }

    /// Answers the next `meta` requests in order; the last one repeats.
    func answerMeta(_ answers: FakeTransport.Answer...) {
        lock.withLock { metaAnswers = answers }
    }

    /// Answers the next requests for this object in order, then the object itself.
    func answerObject(hash: String, fileType: String, _ answers: FakeTransport.Answer...) {
        lock.withLock { objectOverrides["\(hash).\(fileType)"] = answers }
    }

    /// Answers the next manifest requests in order, then manifests by checksum again.
    func answerManifest(_ answers: FakeTransport.Answer...) {
        lock.withLock { manifestOverrides = answers }
    }

    func goOffline(_ value: Bool = true) {
        lock.withLock { offline = value }
    }

    func resetRequests() {
        lock.withLock { recorded = [] }
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        if Release.isObject(request.url!) { onObjectRequest?() }
        let answer = try lock.withLock { () throws -> FakeTransport.Answer in
            recorded.append(request)
            if offline { throw FakeTransport.Offline() }
            let url = request.url!
            if url.path.hasSuffix("/delivery/meta") {
                guard let first = metaAnswers.first else { return FakeTransport.Answer(status: 503) }
                if metaAnswers.count > 1 { metaAnswers.removeFirst() }
                // A real server answers 304 only to a conditional request.
                if first.status == 304, request.value(forHTTPHeaderField: "If-None-Match") == nil, let publishedMeta {
                    return publishedMeta
                }
                return first
            }
            if url.lastPathComponent == "manifest.json" {
                if !manifestOverrides.isEmpty { return manifestOverrides.removeFirst() }
                let checksum = url.deletingLastPathComponent().lastPathComponent
                guard let bytes = manifests[checksum] else { return FakeTransport.Answer(status: 404) }
                return FakeTransport.Answer(status: 200, body: bytes)
            }
            let name = url.lastPathComponent
            if var queue = objectOverrides[name], !queue.isEmpty {
                let next = queue.removeFirst()
                objectOverrides[name] = queue
                return next
            }
            guard let bytes = objects[name] else { return FakeTransport.Answer(status: 404) }
            return FakeTransport.Answer(status: 200, body: bytes)
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: answer.status, httpVersion: "HTTP/1.1", headerFields: answer.headers)!
        return (answer.body ?? Data(), response)
    }
}

/// One release as the server would publish it: manifest bytes, their checksum, a CDN-mode `meta` body, and objects.
struct Release {
    let releaseId: Int
    let checksum: String
    let manifest: Data
    let metaBody: [String: Any]
    let objects: [String: Data]

    static func isObject(_ url: URL) -> Bool {
        url.lastPathComponent.range(of: #"^[0-9a-f]{64}\.[a-z]+$"#, options: .regularExpression) != nil
    }

    /// The release-1 fixture.
    static func one() throws -> Release {
        let manifest = try Fixtures.data("release-1/manifest.json")
        var objects: [String: Data] = [:]
        for name in try FileManager.default.contentsOfDirectory(atPath: Fixtures.url("release-1/objects").path) {
            objects[name] = try Fixtures.data("release-1/objects/\(name)")
        }
        return try make(releaseId: 42, manifest: manifest, objects: objects)
    }

    /// release-1 with some slots' bytes replaced (or slots removed with `nil`), and any manifest field changed.
    func changing(releaseId: Int, slots: [Slot: Data?] = [:], fields: [String: Any] = [:]) throws -> Release {
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: manifest) as? [String: Any])
        var slices = try XCTUnwrap(object["slices"] as? [String: [String: [String: [String: Any]]]])
        var objects = self.objects
        for (slot, data) in slots {
            if let data {
                let hash = Fixtures.sha256Hex(data)
                slices[slot.bundleId, default: [:]][slot.locale, default: [:]][slot.fileType] = ["hash": hash, "size": data.count]
                objects["\(hash).\(slot.fileType)"] = data
            } else {
                slices[slot.bundleId]?[slot.locale]?[slot.fileType] = nil
            }
        }
        object["slices"] = slices
        object.merge(fields) { _, new in new }
        return try Release.make(releaseId: releaseId, manifest: JSONSerialization.data(withJSONObject: object, options: .sortedKeys),
                                objects: objects)
    }

    private static func make(releaseId: Int, manifest: Data, objects: [String: Data]) throws -> Release {
        let checksum = Fixtures.sha256Hex(manifest)
        var meta = try DeliveryFixtures.metaEnvelope("cdn").jsonBody()
        meta["checksum"] = checksum
        meta["releaseId"] = releaseId
        meta["manifestUrl"] = "https://cdn.example.invalid/releases/1/\(checksum)/manifest.json"
        meta["pollAfter"] = 1800
        return Release(releaseId: releaseId, checksum: checksum, manifest: manifest, metaBody: meta, objects: objects)
    }

    /// This release's 200 `meta`, optionally with a renewed signature.
    func metaAnswer(signedQuery: String? = nil) -> FakeTransport.Answer {
        var body = metaBody
        if let signedQuery { body["signedQuery"] = signedQuery }
        return .json(200, body, headers: ["ETag": "\"m\(releaseId)-\(checksum.prefix(8))\""])
    }

    /// The hash the manifest lists for a slot.
    func hash(of slot: Slot) throws -> String {
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: manifest) as? [String: Any])
        let slices = try XCTUnwrap(object["slices"] as? [String: [String: [String: [String: Any]]]])
        return try XCTUnwrap(slices[slot.bundleId]?[slot.locale]?[slot.fileType]?["hash"] as? String)
    }
}
