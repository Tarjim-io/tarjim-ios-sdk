import Foundation

/// A Tarjim bundle, addressed by type AND name: a custom bundle may share a namespace's name.
public enum TarjimBundle: Hashable, Sendable {
    case namespace(String)
    case custom(String)
}

/// One `bundles` entry of a manifest.
struct ManifestBundle: Equatable, Sendable {
    let id: String
    /// `namespace` or `custom`; any other value never matches.
    let type: String
    let name: String
}

enum BundleDirectory {
    static func id(for bundle: TarjimBundle, in entries: [ManifestBundle]) -> String? {
        let (type, name) = switch bundle {
        case .namespace(let name): ("namespace", name)
        case .custom(let name): ("custom", name)
        }
        return entries
            .filter { $0.type == type && $0.name == name }
            .min { lowerId($0.id, than: $1.id) }?.id
    }

    // Numeric order so `ns7` precedes `ns10`; ids without digits sort last. The id breaks ties, which keeps the
    // order total and the answer independent of the entries' order.
    private static func lowerId(_ a: String, than b: String) -> Bool {
        let x = trailingNumber(a) ?? Int.max, y = trailingNumber(b) ?? Int.max
        return x != y ? x < y : a < b
    }

    private static func trailingNumber(_ id: String) -> Int? {
        let digits = id.reversed().prefix { $0.isASCII && $0.isNumber }
        return Int(String(digits.reversed()))
    }
}
