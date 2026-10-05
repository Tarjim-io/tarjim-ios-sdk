import Foundation

/// What every lookup reads: one install, its bundles and the selected locales. Never changes once built.
final class Snapshot: Sendable {
    static let empty = Snapshot(installDirectory: nil, entries: [], selection: nil)

    let installDirectory: URL?
    let entries: [BundleEntry]
    let selection: LocaleSelection?

    init(installDirectory: URL?, entries: [BundleEntry], selection: LocaleSelection?) {
        self.installDirectory = installDirectory
        self.entries = entries
        self.selection = selection
    }
}

final class SnapshotHolder: Sendable {
    init(_ initial: Snapshot = .empty) {}

    var current: Snapshot {
        .empty
    }

    func replace(_ snapshot: Snapshot) {}
}

/// The app's own localized resources.
struct AppResources: Sendable {
    let bundle: Bundle
    /// The app's active localization.
    let language: String
}

struct Resolver: Sendable {
    let app: AppResources
    let defaultBundle: TarjimBundle
    let snapshot: @Sendable () -> Snapshot

    init(app: AppResources, defaultBundle: TarjimBundle, snapshot: @escaping @Sendable () -> Snapshot) {
        self.app = app
        self.defaultBundle = defaultBundle
        self.snapshot = snapshot
    }

    func string(_ key: String, bundle: TarjimBundle? = nil) -> String {
        ""
    }

    func string(_ key: String, arguments: [CVarArg], bundle: TarjimBundle? = nil) -> String {
        ""
    }
}
