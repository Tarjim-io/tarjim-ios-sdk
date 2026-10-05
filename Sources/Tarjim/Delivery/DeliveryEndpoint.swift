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
        guard let parts = URLComponents(url: host, resolvingAgainstBaseURL: false),
              let scheme = parts.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let name = parts.host, !name.isEmpty,
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
              parts.path.isEmpty || parts.path == "/"
        else { throw Error.invalidHost }

        var origin = URLComponents()
        origin.scheme = scheme
        origin.host = name
        origin.port = parts.port
        var meta = origin
        meta.path = "/projects/\(projectId)/delivery/meta"
        guard let originURL = origin.url, let metaURL = meta.url else { throw Error.invalidHost }

        self.host = originURL
        self.projectId = projectId
        self.apiKey = apiKey
        self.metaURL = metaURL
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
        var agent = "Tarjim-iOS/\(sdkVersion) app/\(appVersion) iOS/\(osVersion) lang/\(language)"
        if let installIdentifier {
            agent += " install/\(installIdentifier)"
        }
        return agent
    }
}

extension DeliveryEndpoint: CustomStringConvertible, CustomDebugStringConvertible {
    var description: String { "DeliveryEndpoint(host: \(host.absoluteString), projectId: \(projectId))" }
    var debugDescription: String { description }
}
