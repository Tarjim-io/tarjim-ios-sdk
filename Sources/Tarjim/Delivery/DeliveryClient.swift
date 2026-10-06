import Foundation

/// `meta`, manifest and object requests over an injected transport. Pure: no state, no clock,
/// no file system. Every answer is a typed outcome; nothing here throws.
struct DeliveryClient: Sendable {
    let endpoint: DeliveryEndpoint
    let identity: ClientIdentity
    let transport: any Transport
    let apiVersion: String
    /// Asked for at each request; `identity.language` is only the answer when nothing is supplied.
    let language: @Sendable () -> String

    init(endpoint: DeliveryEndpoint, identity: ClientIdentity, transport: any Transport, apiVersion: String = "2026-07-29",
         language: (@Sendable () -> String)? = nil) {
        self.endpoint = endpoint
        self.identity = identity
        self.language = language ?? { identity.language }
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
            return .received(meta, etag: response.value(forHTTPHeaderField: "ETag"), raw: data)
        case 304:
            return .notModified
        case 429:
            return .throttled(retryAfter: retryAfter)
        case 301, 302, 307, 308:
            // Never followed, and retrying will not help: the endpoint has moved.
            return .configurationError(code: "redirect", pollAfter: nil)
        case 400, 401, 403, 404:
            let problem = try? JSONDecoder().decode(Problem.self, from: data)
            if response.statusCode == 404, let code = problem?.code, Self.unreleasedCodes.contains(code) {
                return .unreleased(pollAfter: problem?.pollAfter)
            }
            return .configurationError(code: problem?.code ?? "unknown", pollAfter: problem?.pollAfter)
        default:
            return .serverError(retryAfter: retryAfter)
        }
    }

    func fetchManifest(_ meta: Meta) async -> ManifestOutcome {
        guard let url = url(for: meta.manifestUrl, meta: meta) else { return .refused }
        switch await get(url, withKey: meta.authenticated) {
        case let .body(bytes):
            guard Verifier.matches(bytes, sha256Hex: meta.checksum) else { return .checksumMismatch }
            guard let manifest = try? JSONDecoder().decode(Manifest.self, from: bytes) else { return .unreadable }
            return .verified(manifest, raw: bytes)
        case let .unfetchable(status, seconds): return .unfetchable(status: status, retryAfter: seconds)
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
        else { return .refused }
        switch await get(url, withKey: meta.authenticated) {
        case let .body(bytes):
            if let expectedSize, bytes.count > expectedSize { return .tooLarge }
            return Verifier.matches(bytes, sha256Hex: hash) ? .verified(bytes) : .hashMismatch
        case let .unfetchable(status, seconds): return .unfetchable(status: status, retryAfter: seconds)
        case let .throttled(seconds): return .throttled(retryAfter: seconds)
        case let .serverError(seconds): return .serverError(retryAfter: seconds)
        case .networkFailure: return .networkFailure
        }
    }

    // MARK: private

    private static let unreleasedCodes: Set<String> = ["delivery.stage_unreleased", "delivery.track_unreleased", "delivery.not_published"]

    /// RFC 3986 query characters; anything else, whitespace and `#` included, would not survive the join.
    private static let queryCharacters = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~!$&'()*+,;=:@/?%")

    private struct Problem: Decodable {
        var code: String?
        var pollAfter: Int?

        private enum CodingKeys: String, CodingKey { case code, pollAfter }

        // Each member is read on its own so a malformed `pollAfter` does not lose the `code`.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            code = try? c.decodeIfPresent(String.self, forKey: .code)
            pollAfter = try? c.decodeIfPresent(Int.self, forKey: .pollAfter)
        }
    }

    private enum Fetched {
        case body(Data)
        case unfetchable(Int, retryAfter: Int?)
        case throttled(Int?)
        case serverError(Int?)
        case networkFailure
    }

    /// The identity travels with the key only: a CDN request carries none of it.
    private func applyIdentity(to request: inout URLRequest, withKey: Bool) {
        guard withKey else { return }
        request.setValue(endpoint.apiKey, forHTTPHeaderField: "X-Tarjim-Apikey")
        request.setValue(apiVersion, forHTTPHeaderField: "X-Tarjim-Api-Version")
        var current = identity
        current.language = language()
        request.setValue(current.userAgent, forHTTPHeaderField: "User-Agent")
    }

    /// `nil` when the reference must not be requested.
    private func url(for reference: String, meta: Meta) -> URL? {
        meta.authenticated ? originURL(reference) : cdnURL(reference, signedQuery: meta.signedQuery)
    }

    /// Origin references are path-relative; one that could leave the meta URL's host would take the
    /// key with it.
    private func originURL(_ reference: String) -> URL? {
        guard !reference.hasPrefix("/"), !reference.contains(".."),
              let parts = URLComponents(string: reference), parts.scheme == nil, parts.host == nil,
              let resolved = URL(string: reference, relativeTo: endpoint.metaURL)?.absoluteURL,
              resolved.scheme == endpoint.metaURL.scheme, resolved.host == endpoint.metaURL.host, resolved.port == endpoint.metaURL.port
        else { return nil }
        return resolved
    }

    /// CDN URLs are joined verbatim; whatever would not survive that unchanged is refused.
    private func cdnURL(_ base: String, signedQuery: String?) -> URL? {
        guard base.hasPrefix("https://"), !base.contains("?"), !base.contains("#") else { return nil }
        var joined = base
        if let signedQuery, !signedQuery.isEmpty {
            guard signedQuery.allSatisfy(Self.queryCharacters.contains) else { return nil }
            joined += "?" + signedQuery
        }
        guard let url = URL(string: joined), url.absoluteString == joined else { return nil }
        return url
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
        let retryAfter = Self.retryAfter(response)
        switch response.statusCode {
        case 200: return .body(data)
        case 429: return .throttled(retryAfter)
        case 400..<500, 503: return .unfetchable(response.statusCode, retryAfter: retryAfter)
        default: return .serverError(retryAfter)
        }
    }

    /// Only the delta-seconds form; an HTTP date is ignored.
    private static func retryAfter(_ response: HTTPURLResponse) -> Int? {
        guard let value = response.value(forHTTPHeaderField: "Retry-After"),
              let seconds = Int(value.trimmingCharacters(in: .whitespaces)), seconds >= 0
        else { return nil }
        return seconds
    }
}

extension DeliveryClient: CustomStringConvertible, CustomDebugStringConvertible {
    var description: String { "DeliveryClient(endpoint: \(endpoint), apiVersion: \(apiVersion))" }
    var debugDescription: String { description }
}

extension DeliveryClient: CustomReflectable {
    var customMirror: Mirror {
        Mirror(self, children: ["endpoint": endpoint, "identity": identity, "apiVersion": apiVersion], displayStyle: .struct)
    }
}
