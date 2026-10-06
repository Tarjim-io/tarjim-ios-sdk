import Foundation

/// One file of a release: a `.strings` table or a one-key `.stringsdict` plural.
enum StubFile: Sendable {
    case strings(namespace: String, locale: String, [String: String])
    case plural(namespace: String, locale: String, key: String, one: String, other: String)
}

/// A release the stub serves, built in code; every hash is computed from the bytes it serves.
struct StubRelease: Sendable {
    let releaseId: Int
    let files: [StubFile]
}

/// What the app sent, as the stub received it.
struct StubRequest: Sendable {
    /// Path and query, as on the request line.
    let target: String
    let headers: [String: String]
}

enum StubError: Error {
    case notImplemented
}

/// A Tarjim delivery server on 127.0.0.1 for the UI tests, in origin delivery mode. The app and the test runner share
/// the host's network on the simulator, so the app reaches it at the URL `start` returns.
final class StubServer: @unchecked Sendable {
    init(release: StubRelease) {}

    /// Starts listening on an ephemeral port and returns `http://localhost:<port>`.
    func start() throws -> URL {
        throw StubError.notImplemented
    }

    /// Closes the listener; the port then refuses connections.
    func stop() {}

    /// Serves `release` from the next request on.
    func publish(_ release: StubRelease) {}

    /// Every request received so far, in order.
    var requests: [StubRequest] { [] }
}
