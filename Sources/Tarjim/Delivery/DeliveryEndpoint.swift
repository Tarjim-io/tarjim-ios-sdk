import Foundation

/// The `meta` URL the console shows as the delivery URL, and the key that reads it.
struct DeliveryEndpoint: Sendable, Equatable {
    enum Error: Swift.Error, Equatable {
        case invalidDeliveryURL
    }

    let apiKey: String
    /// The delivery URL exactly as given. Its path belongs to the server, so it is never parsed or rebuilt.
    let metaURL: URL

    init(deliveryURL: URL, apiKey: String) throws {
        guard let parts = URLComponents(url: deliveryURL, resolvingAgainstBaseURL: false),
              let scheme = parts.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let name = deliveryURL.host, !name.isEmpty, !Self.authority(of: deliveryURL).contains("%"),
              // `URLComponents` decodes an `xn--` host to Unicode and `URL.host` decodes percent escapes, so the
              // raw authority is checked for escapes and `URL.host` supplies the ASCII name.
              // Plain http would put the key on the wire in the clear. Compared on the ASCII host, so an encoded or
              // trailing-dot spelling of a loopback name does not pass.
              scheme == "https" || ["localhost", "127.0.0.1", "::1"].contains(name.lowercased().trimmingCharacters(in: ["[", "]"])),
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
              // A trailing slash would shift where origin-relative references resolve.
              parts.path != "/", parts.path.hasPrefix("/"), !parts.path.hasSuffix("/"),
              Self.pathIsPlain(parts.percentEncodedPath)
        else { throw Error.invalidDeliveryURL }

        self.apiKey = apiKey
        self.metaURL = deliveryURL
    }

    private static func authority(of url: URL) -> Substring {
        let text = url.absoluteString
        guard let separator = text.range(of: "://") else { return "" }
        return text[separator.upperBound...].prefix { $0 != "/" }
    }

    /// Parses only to refuse: dot segments make the requested path and the base for origin references disagree,
    /// and whitespace, control or invisible (format) characters mean a bad paste. Both are checked after decoding, so `%2e` and `%20` count.
    private static func pathIsPlain(_ encodedPath: String) -> Bool {
        for segment in encodedPath.split(separator: "/", omittingEmptySubsequences: false) {
            guard let decoded = String(segment).removingPercentEncoding, decoded != ".", decoded != ".." else { return false }
            if decoded.unicodeScalars.contains(where: { $0.properties.isWhitespace || [.control, .format].contains($0.properties.generalCategory) }) {
                return false
            }
        }
        return true
    }
}

/// What the SDK says about itself: its name in `User-Agent`, and the app in the `meta` query.
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
    /// The app's `CFBundleVersion`; left out when empty or longer than 64 UTF-8 bytes, which no server should store.
    var appBuild: String? = nil

    /// The query parameter names, in the order they are sent.
    private enum Parameter: String {
        case appVersion, platform, sdkVersion, release, pollSeconds, language, osVersion, installId, appBuild
    }

    var userAgent: String {
        "Tarjim-iOS/\(sdkVersion)"
    }

    /// Without the leading `?`. Every value is encoded, so none can add or end a parameter.
    var metaQuery: String {
        var pairs: [(Parameter, String)] = [
            (.appVersion, appVersion), (.platform, "ios"), (.sdkVersion, sdkVersion), (.release, String(releaseId)),
            (.pollSeconds, String(pollAfter)), (.language, language), (.osVersion, osVersion),
        ]
        if let installIdentifier { pairs.append((.installId, installIdentifier)) }
        if let appBuild, !appBuild.isEmpty, appBuild.utf8.count <= 64 { pairs.append((.appBuild, appBuild)) }
        return pairs.map { "\($0.0.rawValue)=\(Self.encoded($0.1))" }.joined(separator: "&")
    }

    private static let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    private static func encoded(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? ""
    }
}

extension DeliveryEndpoint: CustomStringConvertible, CustomDebugStringConvertible {
    var description: String { "DeliveryEndpoint(metaURL: \(metaURL.absoluteString))" }
    var debugDescription: String { description }
}

extension DeliveryEndpoint: CustomReflectable {
    var customMirror: Mirror {
        Mirror(self, children: ["metaURL": metaURL], displayStyle: .struct)
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
