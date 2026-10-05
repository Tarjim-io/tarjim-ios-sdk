import Foundation
import XCTest
@testable import Tarjim

/// The key and the signed query must never reach a log line or a report. The cheapest way they
/// would is a value being interpolated into a string, so every type that holds one must redact
/// itself in both string forms.
final class DeliveryLeakTests: XCTestCase {
    private func descriptions(_ value: Any) -> [String] {
        [String(describing: value), String(reflecting: value)]
    }

    func testEndpointAndClientNeverPrintTheKey() throws {
        let endpoint = try DeliveryFixtures.endpoint()
        let client = DeliveryClient(endpoint: endpoint, identity: DeliveryFixtures.identity, transport: FakeTransport())
        for text in descriptions(endpoint) + descriptions(client) {
            XCTAssertFalse(text.contains(DeliveryFixtures.apiKey), text)
        }
        XCTAssertTrue(String(describing: endpoint).contains("api.example.invalid"), "the host is fine to print")
    }

    func testMetaAndMetaOutcomeNeverPrintTheSignedQuery() throws {
        let meta = try DeliveryFixtures.meta("cdn")
        let signedQuery = try XCTUnwrap(meta.signedQuery)
        let outcome = MetaOutcome.received(meta, etag: "\"e\"", raw: Data(try XCTUnwrap(DeliveryFixtures.metaEnvelope("cdn").body).utf8))
        for text in descriptions(meta) + descriptions(outcome) {
            XCTAssertFalse(text.contains(signedQuery), text)
            XCTAssertFalse(text.contains("Policy=REDACTED"), text)
        }
        XCTAssertTrue(String(describing: meta).contains(meta.checksum.prefix(8)), "the checksum is fine to print")
    }

    func testFailureOutcomesCarryNoSecretAtAll() async throws {
        let transport = FakeTransport()
        for name in ["meta-401-unauthorized", "meta-404-stage-unreleased", "meta-429-too-many-requests", "meta-503-disabled"] {
            transport.enqueue(try DeliveryFixtures.error(name))
        }
        let client = try DeliveryFixtures.client(transport)
        for _ in 0..<4 {
            let outcome = await client.fetchMeta(ifNoneMatch: nil)
            for text in descriptions(outcome) {
                XCTAssertFalse(text.contains(DeliveryFixtures.apiKey), text)
            }
        }
    }
}

extension DeliveryLeakTests {
    /// `dump` and `Mirror` bypass the string conformances; a crash reporter or a developer's debug
    /// print would show the key through them.
    func testReflectionNeverShowsTheKeyOrTheSignedQuery() throws {
        let endpoint = try DeliveryFixtures.endpoint()
        let client = DeliveryClient(endpoint: endpoint, identity: DeliveryFixtures.identity, transport: FakeTransport())
        let meta = try DeliveryFixtures.meta("cdn")
        let signedQuery = try XCTUnwrap(meta.signedQuery)
        for (label, value) in [("endpoint", endpoint as Any), ("client", client as Any), ("meta", meta as Any)] {
            var dumped = ""
            dump(value, to: &dumped)
            XCTAssertFalse(dumped.contains(DeliveryFixtures.apiKey), "\(label) dump")
            XCTAssertFalse(dumped.contains(signedQuery), "\(label) dump")
            let children = Mirror(reflecting: value).children.map { "\($0.label ?? ""): \($0.value)" }.joined(separator: "\n")
            XCTAssertFalse(children.contains(DeliveryFixtures.apiKey), "\(label) mirror")
            XCTAssertFalse(children.contains(signedQuery), "\(label) mirror")
        }
    }
}

final class URLSessionTransportTests: XCTestCase {
    /// A 3xx is returned as the answer, never followed: URLSession would copy `X-Tarjim-Apikey`
    /// onto the request to the `Location` host.
    func testRedirectsAreNotFollowed() async throws {
        RedirectStub.seen.reset()
        let configuration = URLSessionTransport.makeConfiguration()
        configuration.protocolClasses = [RedirectStub.self]
        let transport = URLSessionTransport(configuration: configuration)
        var request = URLRequest(url: URL(string: "https://api.example.invalid/projects/1/delivery/meta")!)
        request.setValue(DeliveryFixtures.apiKey, forHTTPHeaderField: "X-Tarjim-Apikey")
        let (_, response) = try await transport.send(request)
        XCTAssertEqual(response.statusCode, 302)
        XCTAssertEqual(RedirectStub.seen.urls.map(\.host), ["api.example.invalid"], "the Location host was contacted")
    }

    func testSessionHasNoCacheNoCookiesAndSetsNoAcceptEncoding() {
        let configuration = URLSessionTransport.makeConfiguration()
        XCTAssertNil(configuration.urlCache)
        XCTAssertEqual(configuration.requestCachePolicy, .reloadIgnoringLocalCacheData)
        XCTAssertNil(configuration.httpCookieStorage)
        XCTAssertFalse(configuration.httpShouldSetCookies)
        let additional = (configuration.httpAdditionalHeaders ?? [:]).keys.compactMap { $0 as? String }.map { $0.lowercased() }
        XCTAssertFalse(additional.contains("accept-encoding"))
    }
}

/// Answers the first host with a 302 to another host and records every URL the session asked for.
final class RedirectStub: URLProtocol {
    final class Seen: @unchecked Sendable {
        private let lock = NSLock()
        private var list: [URL] = []
        var urls: [URL] { lock.lock(); defer { lock.unlock() }; return list }
        func add(_ url: URL) { lock.lock(); list.append(url); lock.unlock() }
        func reset() { lock.lock(); list = []; lock.unlock() }
    }
    static let seen = Seen()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        Self.seen.add(url)
        if url.host == "api.example.invalid" {
            let target = URL(string: "https://other.example.invalid/elsewhere")!
            let redirect = HTTPURLResponse(url: url, statusCode: 302, httpVersion: "HTTP/1.1", headerFields: ["Location": target.absoluteString])!
            var next = request
            next.url = target
            client?.urlProtocol(self, wasRedirectedTo: next, redirectResponse: redirect)
            client?.urlProtocol(self, didReceive: redirect, cacheStoragePolicy: .notAllowed)
            client?.urlProtocolDidFinishLoading(self)
        } else {
            let ok = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
            client?.urlProtocol(self, didReceive: ok, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data("captured".utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {}
}
