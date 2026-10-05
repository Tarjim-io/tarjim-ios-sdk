import Foundation

/// A Tarjim bundle, addressed by type AND name: a custom bundle may share a namespace's name.
public enum TarjimBundle: Hashable, Sendable {
    case namespace(String)
    case custom(String)
}

/// One `bundles` entry of a manifest.
struct BundleEntry: Equatable, Sendable {
    let id: String
    /// `namespace` or `custom`; any other value never matches.
    let type: String
    let name: String
}

enum BundleDirectory {
    static func id(for bundle: TarjimBundle, in entries: [BundleEntry]) -> String? {
        nil
    }
}
