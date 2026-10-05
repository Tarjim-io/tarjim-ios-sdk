import Foundation

/// What every lookup reads: one install, its bundles and the selected locales. Never changes once built.
final class Snapshot: Sendable {
    static let empty = Snapshot(installDirectory: nil, entries: [], selection: nil)

    let installDirectory: URL?
    let entries: [ManifestBundle]
    let selection: LocaleSelection?
    // Opened here, once, so a lookup never touches the file system.
    private let otaBundles: [OTAKey: Bundle]

    private struct OTAKey: Hashable {
        let id: String
        let locale: String
    }

    init(installDirectory: URL?, entries: [ManifestBundle], selection: LocaleSelection?) {
        self.installDirectory = installDirectory
        self.entries = entries
        self.selection = selection
        var opened: [OTAKey: Bundle] = [:]
        if let installDirectory, let selection {
            for entry in entries {
                for locale in selection.locales {
                    let directory = installDirectory.appendingPathComponent("\(entry.id).bundle", isDirectory: true)
                        .appendingPathComponent("\(locale).lproj", isDirectory: true)
                    var isDirectory: ObjCBool = false
                    guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory),
                          isDirectory.boolValue, let bundle = Bundle(url: directory) else { continue }
                    opened[OTAKey(id: entry.id, locale: locale)] = bundle
                }
            }
        }
        otaBundles = opened
    }

    func otaBundle(id: String, locale: String) -> Bundle? {
        otaBundles[OTAKey(id: id, locale: locale)]
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
    // Listed once at construction: lookups only read these maps.
    private let lprojs: [String: Bundle]
    private let tables: Set<String>
    private let matches = MatchCache()

    // Matching runs Apple's matcher; the answer for a locale never changes, so it is computed once.
    private final class MatchCache: @unchecked Sendable {
        private let lock = NSLock()
        private var folders: [String: String?] = [:]

        func folder(for locale: String, compute: () -> String?) -> String? {
            lock.lock()
            defer { lock.unlock() }
            if let known = folders[locale] { return known }
            let name = compute()
            folders[locale] = .some(name)
            return name
        }
    }

    init(bundle: Bundle, language: String) {
        self.bundle = bundle
        self.language = language
        var lprojs: [String: Bundle] = [:]
        var tables: Set<String> = []
        let directories = bundle.resourceURL.flatMap {
            try? FileManager.default.contentsOfDirectory(at: $0, includingPropertiesForKeys: nil)
        } ?? []
        for directory in directories where directory.pathExtension == "lproj" {
            lprojs[directory.deletingPathExtension().lastPathComponent] = Bundle(url: directory)
            let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
            for file in files where ["strings", "stringsdict"].contains(file.pathExtension) {
                tables.insert(file.deletingPathExtension().lastPathComponent)
            }
        }
        self.lprojs = lprojs
        self.tables = tables
    }

    /// The table named after a Tarjim bundle when the app ships one, else the default (`Localizable`).
    func table(named name: String) -> String? {
        tables.contains(name) ? name : nil
    }

    /// The app's folder for a selected locale, found with the selector's own rule; `Base` never matches.
    func lproj(matching locale: String) -> Bundle? {
        let name = matches.folder(for: locale) {
            let names = lprojs.keys.filter { $0 != "Base" }.sorted()
            return LocaleSelector.match(preference: locale, available: names).first
        }
        return name.flatMap { lprojs[$0] }
    }
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
    static let sentinel = "tarjim-missing-" + String(UnicodeScalar(1))

    private func resolve(_ key: String, arguments: [CVarArg]?, bundle: TarjimBundle?) -> String {
        let snapshot = snapshot()
        let name = Self.name(of: bundle ?? defaultBundle)
        let table = app.table(named: name)
        let id = BundleDirectory.id(for: bundle ?? defaultBundle, in: snapshot.entries)
        let locales = snapshot.selection?.locales ?? []

        // Set once the app bundle itself has answered, so a miss is never asked of it twice.
        var askedApp = false
        let steps: [() -> String?]
        switch snapshot.selection?.kind {
        case .user:
            steps = [
                { ota(key, arguments, snapshot, id, locales) },
                { appInSelectedLocale(key, arguments, table, locales, askedApp: &askedApp) },
                { askedApp ? nil : appAsResolved(key, arguments, table) },
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
        guard let id else { return nil }
        for locale in locales {
            guard let lproj = snapshot.otaBundle(id: id, locale: locale), let value = found(lproj, key, table: nil) else { continue }
            return format(value, arguments, locale: locale)
        }
        return nil
    }

    private func appInSelectedLocale(_ key: String, _ arguments: [CVarArg]?, _ table: String?,
                                     _ locales: [String], askedApp: inout Bool) -> String? {
        let resolved = app.lproj(matching: app.language)
        for locale in locales {
            // With the proxy on, the app bundle answers for the folder it resolves to, through its original lookup:
            // the same text, and the app's own lookup (and any earlier patch of it) is reached on every miss.
            if MainBundleProxy.isInstalled(on: app.bundle), let resolved, app.lproj(matching: locale) === resolved {
                if askedApp { continue }
                askedApp = true
                if let value = appAsResolved(key, arguments, table) { return value }
                continue
            }
            guard let lproj = app.lproj(matching: locale), let value = found(lproj, key, table: table) else { continue }
            return format(value, arguments, locale: locale)
        }
        return nil
    }

    private func appAsResolved(_ key: String, _ arguments: [CVarArg]?, _ table: String?) -> String? {
        let value: String
        if MainBundleProxy.isInstalled(on: app.bundle) {
            // The patched lookup would ask the download again; the original answers with the app's own text.
            value = MainBundleProxy.original(app.bundle, key: key, value: Self.sentinel, table: table)
        } else {
            value = app.bundle.localizedString(forKey: key, value: Self.sentinel, table: table)
        }
        return value == Self.sentinel ? nil : format(value, arguments, locale: app.language)
    }

    /// The OTA lookup without formatting, for the proxy.
    func ota(raw key: String, snapshot: Snapshot, id: String, locales: [String]) -> MainBundleProxy.DownloadedText? {
        for locale in locales {
            if let lproj = snapshot.otaBundle(id: id, locale: locale), let value = found(lproj, key, table: nil) {
                return MainBundleProxy.DownloadedText(value: value, source: lproj)
            }
        }
        return nil
    }

    func found(_ bundle: Bundle, _ key: String, table: String?) -> String? {
        let value = bundle.localizedString(forKey: key, value: Self.sentinel, table: table)
        return value == Self.sentinel ? nil : value
    }

    private func format(_ value: String, _ arguments: [CVarArg]?, locale: String) -> String {
        guard let arguments else { return value }
        return String(format: value, locale: Locale(identifier: locale), arguments: arguments)
    }

    private static func name(of bundle: TarjimBundle) -> String {
        switch bundle {
        case .namespace(let name), .custom(let name): name
        }
    }
}
