import Foundation

/// What every lookup reads: one install, its bundles and the selected locales. Never changes once built.
final class Snapshot: Sendable {
    static let empty = Snapshot(installDirectory: nil, entries: [], selection: nil)

    let installDirectory: URL?
    let entries: [ManifestBundle]
    let selection: LocaleSelection?

    init(installDirectory: URL?, entries: [ManifestBundle], selection: LocaleSelection?) {
        self.installDirectory = installDirectory
        self.entries = entries
        self.selection = selection
    }
}

final class SnapshotHolder: Sendable {
    private let storage: Storage

    init(_ initial: Snapshot = .empty) {
        storage = Storage(initial)
    }

    var current: Snapshot {
        storage.read()
    }

    func replace(_ snapshot: Snapshot) {
        storage.write(snapshot)
    }

    private final class Storage: @unchecked Sendable {
        private let lock = NSLock()
        private var snapshot: Snapshot

        init(_ snapshot: Snapshot) {
            self.snapshot = snapshot
        }

        func read() -> Snapshot {
            lock.lock()
            defer { lock.unlock() }
            return snapshot
        }

        func write(_ new: Snapshot) {
            lock.lock()
            defer { lock.unlock() }
            snapshot = new
        }
    }
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
        resolve(key, arguments: nil, bundle: bundle)
    }

    func string(_ key: String, arguments: [CVarArg], bundle: TarjimBundle? = nil) -> String {
        resolve(key, arguments: arguments, bundle: bundle)
    }

    // A real translation can be any string, so a miss is told apart by a value no one would write.
    private static let sentinel = "tarjim-missing-" + String(UnicodeScalar(1))

    private func resolve(_ key: String, arguments: [CVarArg]?, bundle: TarjimBundle?) -> String {
        let snapshot = snapshot()
        let name = Self.name(of: bundle ?? defaultBundle)
        let table = appTable(named: name)
        let id = BundleDirectory.id(for: bundle ?? defaultBundle, in: snapshot.entries)
        let locales = snapshot.selection?.locales ?? []

        let steps: [() -> String?]
        switch snapshot.selection?.kind {
        case .user:
            steps = [
                { ota(key, arguments, snapshot, id, locales) },
                { appInSelectedLocale(key, arguments, table, locales) },
                { appAsResolved(key, arguments, table) },
            ]
        case .fallback:
            steps = [
                { appAsResolved(key, arguments, table) },
                { ota(key, arguments, snapshot, id, locales) },
            ]
        case nil:
            steps = [{ appAsResolved(key, arguments, table) }]
        }
        for step in steps {
            if let value = step() { return value }
        }
        return key
    }

    private func ota(_ key: String, _ arguments: [CVarArg]?, _ snapshot: Snapshot, _ id: String?,
                     _ locales: [String]) -> String? {
        guard let id, let root = snapshot.installDirectory else { return nil }
        for locale in locales {
            let directory = root.appendingPathComponent("\(id).bundle", isDirectory: true)
                .appendingPathComponent("\(locale).lproj", isDirectory: true)
            guard Self.isDirectory(directory), let lproj = Bundle(url: directory),
                  let value = found(lproj, key, table: nil) else { continue }
            return format(value, arguments, locale: locale)
        }
        return nil
    }

    private func appInSelectedLocale(_ key: String, _ arguments: [CVarArg]?, _ table: String?,
                                     _ locales: [String]) -> String? {
        for locale in locales {
            guard let directory = appLproj(for: locale) else { continue }
            guard let lproj = Bundle(url: directory) else { return nil }
            return found(lproj, key, table: table).map { format($0, arguments, locale: locale) }
        }
        return nil
    }

    private func appAsResolved(_ key: String, _ arguments: [CVarArg]?, _ table: String?) -> String? {
        found(app.bundle, key, table: table).map { format($0, arguments, locale: app.language) }
    }

    private func found(_ bundle: Bundle, _ key: String, table: String?) -> String? {
        let value = bundle.localizedString(forKey: key, value: Self.sentinel, table: table)
        return value == Self.sentinel ? nil : value
    }

    private func format(_ value: String, _ arguments: [CVarArg]?, locale: String) -> String {
        guard let arguments else { return value }
        return String(format: value, locale: Locale(identifier: locale), arguments: arguments)
    }

    private func appLproj(for locale: String) -> URL? {
        appLprojDirectories().first { $0.deletingPathExtension().lastPathComponent.caseInsensitiveCompare(locale) == .orderedSame }
    }

    // Looked up by table name: an app that ships `<name>.strings` keeps its text there, not in `Localizable`.
    private func appTable(named name: String) -> String? {
        let fileManager = FileManager.default
        for directory in appLprojDirectories() {
            for ext in ["strings", "stringsdict"]
            where fileManager.fileExists(atPath: directory.appendingPathComponent("\(name).\(ext)").path) {
                return name
            }
        }
        return nil
    }

    private func appLprojDirectories() -> [URL] {
        guard let root = app.bundle.resourceURL,
              let entries = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        else { return [] }
        return entries.filter { $0.pathExtension == "lproj" }
    }

    private static func name(of bundle: TarjimBundle) -> String {
        switch bundle {
        case .namespace(let name), .custom(let name): name
        }
    }

    private static func isDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }
}
