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
              // Plain http would put the key on the wire in the clear.
              scheme == "https" || ["localhost", "127.0.0.1", "::1"].contains(name.lowercased().trimmingCharacters(in: ["[", "]"])),
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
    /// A random per-install identifier, sent only when set.
    var installIdentifier: String?
    /// The release of the install lookups read; 0 before any is shown.
    var releaseId: Int = 0
    /// The `pollAfter` the schedule follows; 0 before any `meta` answered.
    var pollAfter: Int = 0

    var userAgent: String {
        var tokens = [("Tarjim-iOS", sdkVersion), ("app", appVersion), ("ios", osVersion), ("lang", language),
                      ("rel", String(releaseId)), ("poll", String(pollAfter))]
        if let installIdentifier { tokens.append(("install", installIdentifier)) }
        return tokens.map { "\($0.0)/\(Self.encoded($0.1))" }.joined(separator: " ")
    }

    // Space and `/` are encoded too, so the line is always single-space-separated `token/value` pairs.
    private static let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    private static func encoded(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? ""
    }
}

extension DeliveryEndpoint: CustomStringConvertible, CustomDebugStringConvertible {
    var description: String { "DeliveryEndpoint(host: \(host.absoluteString), projectId: \(projectId))" }
    var debugDescription: String { description }
}

extension DeliveryEndpoint: CustomReflectable {
    var customMirror: Mirror {
        Mirror(self, children: ["host": host, "projectId": projectId, "metaURL": metaURL], displayStyle: .struct)
    }
}

/// The app's version in the one form the server accepts.
enum AppVersion {
    private static let fallback = "0.0.0"

    static func core(of version: String) -> String {
        var parts: [Int] = []
        var rest = Substring(version)
        // Parts past the third are dropped unparsed: an overflowing fourth must not force the fallback.
        while parts.count < 3 {
            let digits = rest.prefix { $0.isASCII && $0.isNumber }
            guard !digits.isEmpty else { break }
            guard let number = Int(digits) else { return fallback }
            parts.append(number)
            rest = rest.dropFirst(digits.count)
            guard rest.first == "." else { break }
            rest = rest.dropFirst()
        }
        guard !parts.isEmpty else { return fallback }
        let core = (parts + [0, 0, 0]).prefix(3).map(String.init).joined(separator: ".")
        return core.count <= 32 ? core : fallback
    }
}
