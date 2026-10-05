import Foundation

/// One HTTP exchange. Throws only when no response arrived (a network failure); a non-2xx
/// answer is returned, not thrown, so callers can read its status, headers and body.
protocol Transport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

struct URLSessionTransport: Transport {
    private let session: URLSession

    init() {
        self.init(configuration: Self.makeConfiguration())
    }

    /// `configuration` lets a test install a stub `URLProtocol`; the session's policies (no
    /// redirects) apply regardless of the configuration given.
    init(configuration: URLSessionConfiguration) {
        session = URLSession(configuration: configuration, delegate: RefuseRedirects(), delegateQueue: nil)
    }

    static func makeConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        return configuration
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        return (data, http)
    }
}

/// URLSession would follow a 3xx and copy the request's headers, `X-Tarjim-Apikey` included, onto
/// the `Location` host. Answering `nil` hands the 3xx back as the response instead.
private final class RefuseRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}
