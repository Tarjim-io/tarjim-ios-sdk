import Foundation

/// Where one project's delivery routes live, and the key that reads them.
struct DeliveryEndpoint: Sendable, Equatable {
    enum Error: Swift.Error, Equatable {
        case invalidHost
    }

    /// Scheme and host (and port) only.
    let host: URL
    let projectId: Int
    let apiKey: String
    /// `<host>/projects/<projectId>/delivery/meta`, never with a trailing slash.
    let metaURL: URL

    init(host: URL, projectId: Int, apiKey: String) throws {
        self.host = host
        self.projectId = projectId
        self.apiKey = apiKey
        metaURL = host
    }
}

/// What the SDK says about itself in `User-Agent`.
struct ClientIdentity: Sendable, Equatable {
    var sdkVersion: String
    var appVersion: String
    var osVersion: String
    var language: String
    /// A random per-install identifier; sent only when set. Whether it is set by default is not
    /// this type's decision.
    var installIdentifier: String?

    var userAgent: String {
        ""
    }
}
