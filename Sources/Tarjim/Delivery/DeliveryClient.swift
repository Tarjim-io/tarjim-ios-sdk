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
        var request = URLRequest(url: endpoint.metaURL)
        applyIdentity(to: &request, withKey: true)
        if let etag {
            request.setValue(etag, forHTTPHeaderField: "If-None-Match")
        }
        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await transport.send(request)
        } catch {
            return .networkFailure
        }
        let retryAfter = Self.retryAfter(response)
        switch response.statusCode {
        case 200:
            guard let meta = try? JSONDecoder().decode(Meta.self, from: data) else { return .unreadable }
            return .changed(meta, etag: response.value(forHTTPHeaderField: "ETag"), raw: data)
        case 304:
            return .notModified
        case 429:
            return .throttled(retryAfter: retryAfter)
        case 400..<500:
            let problem = try? JSONDecoder().decode(Problem.self, from: data)
            if response.statusCode == 404, problem?.code == "delivery.stage_unreleased" {
                return .unreleased(pollAfter: problem?.pollAfter)
            }
            return .configurationError(code: problem?.code ?? "unknown", pollAfter: problem?.pollAfter)
        default:
            return .serverError(retryAfter: retryAfter)
        }
    }

    func fetchManifest(_ meta: Meta) async -> ManifestOutcome {
        guard let url = url(for: meta.manifestUrl, meta: meta) else { return .unfetchable(status: 0) }
        switch await get(url, withKey: meta.authenticated) {
        case let .body(bytes):
            guard Verifier.matches(bytes, sha256Hex: meta.checksum) else { return .checksumMismatch }
            guard let manifest = try? JSONDecoder().decode(Manifest.self, from: bytes) else { return .unreadable }
            return .verified(manifest, raw: bytes)
        case let .unfetchable(status): return .unfetchable(status: status)
        case let .throttled(seconds): return .throttled(retryAfter: seconds)
        case let .serverError(seconds): return .serverError(retryAfter: seconds)
        case .networkFailure: return .networkFailure
        }
    }

    func fetchObject(_ meta: Meta, hash: String, fileType: String, expectedSize: Int?) async -> ObjectOutcome {
        // Both come from a downloaded manifest and become part of a URL.
        guard hash.count == 64, hash.allSatisfy({ $0.isASCII && ($0.isNumber || ("a"..."f").contains($0)) }),
              !fileType.isEmpty, fileType.allSatisfy({ $0.isASCII && $0.isLowercase && $0.isLetter }),
              let url = url(for: meta.slicesBaseUrl + hash + "." + fileType, meta: meta)
        else { return .unfetchable(status: 0) }
        switch await get(url, withKey: meta.authenticated) {
        case let .body(bytes):
            if let expectedSize, bytes.count > expectedSize { return .tooLarge }
            return Verifier.matches(bytes, sha256Hex: hash) ? .verified(bytes) : .hashMismatch
        case let .unfetchable(status): return .unfetchable(status: status)
        case let .throttled(seconds): return .throttled(retryAfter: seconds)
        case let .serverError(seconds): return .serverError(retryAfter: seconds)
        case .networkFailure: return .networkFailure
        }
    }

    // MARK: private

    private struct Problem: Decodable {
        var code: String?
        var pollAfter: Int?
    }

    private enum Fetched {
        case body(Data)
        case unfetchable(Int)
        case throttled(Int?)
        case serverError(Int?)
        case networkFailure
    }

    private func applyIdentity(to request: inout URLRequest, withKey: Bool) {
        if withKey {
            request.setValue(endpoint.apiKey, forHTTPHeaderField: "X-Tarjim-Apikey")
            request.setValue(apiVersion, forHTTPHeaderField: "X-Tarjim-Api-Version")
        }
        request.setValue(identity.userAgent, forHTTPHeaderField: "User-Agent")
    }

    /// `nil` when the reference is not safe to request. In origin mode the key travels with the
    /// request, so a reference that could leave the meta URL's host or directory is refused.
    private func url(for reference: String, meta: Meta) -> URL? {
        guard meta.authenticated else {
            let query = meta.signedQuery.map { "?" + $0 } ?? ""
            return URL(string: reference + query)
        }
        guard !reference.hasPrefix("/"), !reference.contains(".."),
              let parts = URLComponents(string: reference), parts.scheme == nil, parts.host == nil
        else { return nil }
        return URL(string: reference, relativeTo: endpoint.metaURL)?.absoluteURL
    }

    private func get(_ url: URL, withKey: Bool) async -> Fetched {
        var request = URLRequest(url: url)
        applyIdentity(to: &request, withKey: withKey)
        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await transport.send(request)
        } catch {
            return .networkFailure
        }
        switch response.statusCode {
        case 200: return .body(data)
        case 403, 404, 503: return .unfetchable(response.statusCode)
        case 429: return .throttled(Self.retryAfter(response))
        default: return .serverError(Self.retryAfter(response))
        }
    }

    /// Only the delta-seconds form; an HTTP date is ignored.
    private static func retryAfter(_ response: HTTPURLResponse) -> Int? {
        response.value(forHTTPHeaderField: "Retry-After").flatMap { Int($0) }.flatMap { $0 >= 0 ? $0 : nil }
    }
}

extension DeliveryClient: CustomStringConvertible, CustomDebugStringConvertible {
    var description: String { "DeliveryClient(endpoint: \(endpoint), apiVersion: \(apiVersion))" }
    var debugDescription: String { description }
}
