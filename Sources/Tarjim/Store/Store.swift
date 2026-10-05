import CryptoKit
import Foundation

enum StoreError: Error, Equatable {
    /// A checksum, hash, file type, bundle id or locale that is not safe as a path component.
    case unsafeName(String)
    case hashMismatch
    /// `activate` or `setPending` was given an install whose directory is not on disk.
    case missingInstall(String)
}

enum StoreIdentifier {
    static func make(host: URL, projectId: Int, apiKey: String) -> String {
        let digest = SHA256.hash(data: Data("\(host.absoluteString)\n\(projectId)\n\(apiKey)".utf8))
        return String(hex(digest).prefix(32))
    }
}

private func hex<D: Sequence>(_ bytes: D) -> String where D.Element == UInt8 {
    bytes.map { String(format: "%02x", $0) }.joined()
}

/// Private to the Store: what an install records about the files it holds.
private struct InstallManifest: Codable {
    let checksum: String
    let releaseId: Int?
    /// `<bundle>/<locale>/<fileType>` to the hash of the bytes written.
    let files: [String: String]
}

/// Highest install number handed out per store directory in this process.
private final class InstallNumbers: @unchecked Sendable {
    private static let shared = InstallNumbers()
    private let lock = NSLock()
    private var highest: [String: Int] = [:]

    static func highest(for directory: URL) -> Int {
        shared.lock.withLock { shared.highest[directory.path] ?? 0 }
    }

    static func record(_ number: Int, for directory: URL) {
        shared.lock.withLock { shared.highest[directory.path] = max(shared.highest[directory.path] ?? 0, number) }
    }
}

/// The only code that writes files. Takes verified bytes; never talks to the network.
actor Store {
    nonisolated let directory: URL
    private(set) var state: StoreState
    private var protectedDirectories: Set<String> = []
    /// Built but not yet recorded: `cleanup` may run in between. Recording one releases only that one; an
    /// abandoned build stays until the next launch's cleanup.
    /// `<hash>.<fileType>` to candidate files; rebuilt after anything that can change what is on disk or what is bad.
    private var heldIndex: [String: [URL]]?
    private var unrecordedInstalls: Set<String> = []

    init(root: URL, identifier: String, sdkVersion: String) throws {
        let tarjim = root.appendingPathComponent("Tarjim", isDirectory: true)
        directory = tarjim.appendingPathComponent("v1/\(identifier)", isDirectory: true)
        let fileManager = FileManager.default
        for name in ["", "staging", "installs"] {
            try fileManager.createDirectory(at: directory.appendingPathComponent(name), withIntermediateDirectories: true)
        }
        var tarjimURL = tarjim
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try tarjimURL.setResourceValues(values)
        state = Store.loadState(from: directory.appendingPathComponent("state.json"), sdkVersion: sdkVersion)
    }

    private static func loadState(from file: URL, sdkVersion: String) -> StoreState {
        guard let data = try? Data(contentsOf: file),
              var loaded = try? JSONDecoder().decode(StoreState.self, from: data),
              loaded.formatVersion == StoreState.currentFormatVersion
        else { return StoreState(sdkVersion: sdkVersion) }
        if loaded.sdkVersion != sdkVersion {
            loaded.rejectedChecksums = []
            loaded.sdkVersion = sdkVersion
        }
        return sanitised(loaded)
    }

    /// state.json is data from disk: its names become path components, so they are checked like server input.
    private static func sanitised(_ state: StoreState) -> StoreState {
        var state = namesSanitised(state)
        if !(1...maxInstallNumber).contains(state.nextInstallNumber) { state.nextInstallNumber = 1 }
        return state
    }

    private static func namesSanitised(_ state: StoreState) -> StoreState {
        var state = state
        if let checksum = state.stagingChecksum, !isSafe(checksum: checksum) { state.stagingChecksum = nil }
        if let record = state.active, !isConsistent(record) { state.active = nil }
        if let record = state.previous, !isConsistent(record) { state.previous = nil }
        if let record = state.pending, !isConsistent(record) { state.pending = nil }
        return state
    }

    private static let maxInstallNumber = 1_000_000_000

    private static func isConsistent(_ record: InstallRecord) -> Bool {
        guard isSafe(checksum: record.checksum), let number = installNumber(record.directory), number > 0 else { return false }
        return record.directory == "\(number)-\(record.checksum.prefix(8))"
    }

    func save(_ state: StoreState) throws {
        let state = Store.namesSanitised(state)
        heldIndex = nil
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let data = try encoder.encode(state)
        let temp = directory.appendingPathComponent(".state-\(UUID().uuidString).tmp")
        let target = directory.appendingPathComponent("state.json")
        do {
            try data.write(to: temp)
            // rename(2) replaces the target in one step; a reader sees the old or the new file, never a mix.
            guard rename(temp.path, target.path) == 0 else { throw CocoaError(.fileWriteUnknown) }
        } catch {
            try? FileManager.default.removeItem(at: temp)
            throw error
        }
        self.state = state
    }

    func stage(checksum: String, hash: String, fileType: String, verifiedBytes: Data) throws {
        try Store.requireSafe(checksum: checksum, hash: hash, fileType: fileType)
        guard Store.sha256Hex(verifiedBytes) == hash else { throw StoreError.hashMismatch }
        heldIndex = nil
        let staging = stagingDirectory(checksum)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        // The leading dot keeps a half-written file from matching what `stagedObjects` accepts.
        let temp = staging.appendingPathComponent(".\(UUID().uuidString).tmp")
        let target = staging.appendingPathComponent("\(hash).\(fileType)")
        do {
            try verifiedBytes.write(to: temp)
            guard rename(temp.path, target.path) == 0 else { throw CocoaError(.fileWriteUnknown) }
        } catch {
            try? FileManager.default.removeItem(at: temp)
            throw error
        }
        if state.stagingChecksum != checksum {
            var next = state
            next.stagingChecksum = checksum
            try save(next)
        }
    }

    func stagedObjects(checksum: String) -> Set<String> {
        guard Store.isSafe(checksum: checksum) else { return [] }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: stagingDirectory(checksum).path)) ?? []
        return Set(names.filter { name in
            let parts = name.split(separator: ".", omittingEmptySubsequences: false)
            return parts.count == 2 && Store.isSafe(hash: String(parts[0])) && Store.isSafe(fileType: String(parts[1]))
                && isRegularFile(stagingDirectory(checksum).appendingPathComponent(name))
        })
    }

    func heldObject(hash: String, fileType: String) -> URL? {
        if heldIndex == nil { heldIndex = buildHeldIndex() }
        // A file cut short keeps its name; what is held must be what `makeInstall` would accept.
        return heldIndex?["\(hash).\(fileType)"]?.first {
            (try? Data(contentsOf: $0)).map { Store.sha256Hex($0) == hash } ?? false
        }
    }

    private func buildHeldIndex() -> [String: [URL]] {
        var index = installedCandidates()
        // The staging directory goes first: it is the freshest source.
        if let checksum = state.stagingChecksum, Store.isSafe(checksum: checksum), !state.badChecksums.contains(checksum) {
            for name in stagedObjects(checksum: checksum) {
                index[name, default: []].insert(stagingDirectory(checksum).appendingPathComponent(name), at: 0)
            }
        }
        return index
    }

    /// `<hash>.<fileType>` to the files of every install on disk that lists it, newest install first. Any install, not
    /// just the ones state.json names: a rollback target may be none of them.
    private func installedCandidates() -> [String: [URL]] {
        var index: [String: [URL]] = [:]
        for name in installDirectoryNames().reversed() {
            guard let manifest = readInstallManifest(named: name), !state.badChecksums.contains(manifest.checksum) else { continue }
            for (key, fileHash) in manifest.files.sorted(by: { $0.key < $1.key }) {
                guard let slot = Store.slot(fromKey: key) else { continue }
                index["\(fileHash).\(slot.fileType)", default: []].append(fileURL(installNamed: name, slot: slot))
            }
        }
        return index
    }

    private func installDirectoryNames() -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.appendingPathComponent("installs").path)) ?? []
        return names.sorted { (Store.installNumber($0) ?? 0, $0) < (Store.installNumber($1) ?? 0, $1) }
    }

    private static func installNumber(_ name: String) -> Int? {
        name.split(separator: "-").first.flatMap { Int($0) }
    }

    private func readInstallManifest(named name: String) -> InstallManifest? {
        let file = directory.appendingPathComponent("installs/\(name)/install.json")
        return (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode(InstallManifest.self, from: $0) }
    }

    private static func key(for slot: Slot) -> String {
        "\(slot.bundleId)/\(slot.locale)/\(slot.fileType)"
    }

    private static func slot(fromKey key: String) -> Slot? {
        let parts = key.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        return parts.count == 3 ? Slot(bundleId: parts[0], locale: parts[1], fileType: parts[2]) : nil
    }

    private func stagingDirectory(_ checksum: String) -> URL {
        directory.appendingPathComponent("staging/\(checksum)", isDirectory: true)
    }

    private func isRegularFile(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true
    }

    private static func requireSafe(checksum: String, hash: String, fileType: String) throws {
        guard isSafe(checksum: checksum) else { throw StoreError.unsafeName(checksum) }
        guard isSafe(hash: hash) else { throw StoreError.unsafeName(hash) }
        guard isSafe(fileType: fileType) else { throw StoreError.unsafeName(fileType) }
    }

    private static func isSafe(checksum: String) -> Bool { isSafe(hash: checksum) }

    private static func isSafe(hash: String) -> Bool {
        hash.utf8.count == 64 && hash.utf8.allSatisfy { ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102) }
    }

    private static func isSafe(fileType: String) -> Bool {
        !fileType.isEmpty && fileType.utf8.allSatisfy { ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 122) }
    }

    private static func sha256Hex(_ data: Data) -> String {
        hex(SHA256.hash(data: data))
    }

    func makeInstall(_ plan: InstallPlan) throws -> InstallRecord {
        guard Store.isSafe(checksum: plan.checksum) else { throw StoreError.unsafeName(plan.checksum) }
        let number = nextFreeInstallNumber()
        let name = "\(number)-\(plan.checksum.prefix(8))"
        let build = stagingDirectory(plan.checksum).appendingPathComponent("build-\(number)", isDirectory: true)
        let fileManager = FileManager.default
        var owed: Set<Slot> = []
        var written: [String: String] = [:]
        var claimedPaths: Set<String> = []
        do {
            // A crash can leave this very directory behind; whatever it holds must not leak into the install.
            try? fileManager.removeItem(at: build)
            try fileManager.createDirectory(at: build, withIntermediateDirectories: true)
            let sources = InstallSources(store: self, plan: plan)
            var candidates: [(slot: Slot, hash: String, data: Data?)] = []
            for slot in installableSlots(plan) {
                guard let hash = plan.listed[slot] else { continue }
                guard Store.isSafe(hash: hash) else { throw StoreError.unsafeName(hash) }
                candidates.append((slot, hash, sources.verifiedData(hash: hash, fileType: slot.fileType)))
            }
            // Slots with bytes first, so a case twin with nothing to write cannot take the path from one that has.
            for (slot, hash, data) in candidates.filter({ $0.data != nil }) + candidates.filter({ $0.data == nil }) {
                var content = data
                var contentHash = hash
                if content == nil {
                    owed.insert(slot)
                    guard let carried = sources.activeData(for: slot) else { continue }
                    (content, contentHash) = (carried.0, carried.1)
                }
                guard let content else { continue }
                // On a case-insensitive volume `EN` and `en` are one file; the first one written keeps it.
                guard claimedPaths.insert(Store.relativePath(of: slot).lowercased()).inserted else { continue }
                try writeFile(content, in: build, slot: slot, baseLocale: plan.baseLocale)
                written[Store.key(for: slot)] = contentHash
            }
            try plan.manifestRaw.write(to: build.appendingPathComponent("manifest.json"))
            let record = InstallManifest(checksum: plan.checksum, releaseId: plan.releaseId, files: written)
            try JSONEncoder().encode(record).write(to: build.appendingPathComponent("install.json"))
            try fileManager.moveItem(at: build, to: directory.appendingPathComponent("installs/\(name)", isDirectory: true))
        } catch {
            try? fileManager.removeItem(at: build)
            throw error
        }
        heldIndex = nil
        unrecordedInstalls.insert(name)
        InstallNumbers.record(number, for: directory)
        var next = state
        next.nextInstallNumber = number + 1
        try save(next)
        return InstallRecord(directory: name, checksum: plan.checksum, releaseId: plan.releaseId, owedSlots: owed)
    }

    /// Above everything this process handed out and everything on disk, so a counter lost to a crash, a rollback or a
    /// corrupt value never makes a path repeat; and never on a number any install already uses, whatever its checksum.
    private func nextFreeInstallNumber() -> Int {
        let counter = (1...Store.maxInstallNumber).contains(state.nextInstallNumber) ? state.nextInstallNumber : 1
        let used = Set(installDirectoryNames().compactMap(Store.installNumber).map { min($0, Store.maxInstallNumber) })
        var number = max(counter, InstallNumbers.highest(for: directory) + 1, (used.max() ?? 0) + 1)
        while used.contains(number) { number += 1 }
        return number
    }

    /// Only Apple's two formats with names safe as path components; anything else is neither written nor owed.
    private func installableSlots(_ plan: InstallPlan) -> [Slot] {
        plan.wanted.intersection(plan.listed.keys)
            .filter { ($0.fileType == "strings" || $0.fileType == "stringsdict")
                && Store.isSafeComponent($0.bundleId) && Store.isSafeComponent($0.locale) }
            .sorted { Store.key(for: $0) < Store.key(for: $1) }
    }

    /// Where an install's files may come from, gathered once so a release of hundreds of slots stays linear.
    private struct InstallSources {
        private var staged: [URL] = []
        private var stagedNames: [Set<String>] = []
        private var installed: [String: [URL]]
        private var active: (manifest: InstallManifest, directory: URL)?

        init(store: isolated Store, plan: InstallPlan) {
            installed = store.installedCandidates()
            var checksums = [plan.checksum]
            if let held = store.state.stagingChecksum, held != plan.checksum, Store.isSafe(checksum: held) { checksums.append(held) }
            for checksum in checksums where !store.state.badChecksums.contains(checksum) {
                staged.append(store.stagingDirectory(checksum))
                stagedNames.append(store.stagedObjects(checksum: checksum))
            }
            if let record = store.state.active, !store.state.badChecksums.contains(record.checksum),
               let manifest = store.readInstallManifest(named: record.directory) {
                active = (manifest, store.directory.appendingPathComponent("installs/\(record.directory)", isDirectory: true))
            }
        }

        /// The first source whose bytes still hash to `hash`: a file can be cut short while its name stays.
        func verifiedData(hash: String, fileType: String) -> Data? {
            let name = "\(hash).\(fileType)"
            var urls: [URL] = []
            for (directory, names) in zip(staged, stagedNames) where names.contains(name) {
                urls.append(directory.appendingPathComponent(name))
            }
            urls += installed[name] ?? []
            for url in urls {
                if let data = try? Data(contentsOf: url), Store.sha256Hex(data) == hash { return data }
            }
            return nil
        }

        /// The file the user sees now, carried over for a slot the release does not yet have.
        func activeData(for slot: Slot) -> (Data, String)? {
            guard let active, let hash = active.manifest.files[Store.key(for: slot)],
                  let data = try? Data(contentsOf: Store.fileURL(in: active.directory, slot: slot)),
                  Store.sha256Hex(data) == hash else { return nil }
            return (data, hash)
        }
    }

    private func writeFile(_ data: Data, in install: URL, slot: Slot, baseLocale: String?) throws {
        let bundle = install.appendingPathComponent("\(slot.bundleId).bundle", isDirectory: true)
        let lproj = bundle.appendingPathComponent("\(slot.locale).lproj", isDirectory: true)
        try FileManager.default.createDirectory(at: lproj, withIntermediateDirectories: true)
        let plist = bundle.appendingPathComponent("Info.plist")
        if !FileManager.default.fileExists(atPath: plist.path) {
            let info: [String: Any] = ["CFBundlePackageType": "BNDL", "CFBundleDevelopmentRegion": baseLocale ?? "en"]
            try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: plist)
        }
        try data.write(to: lproj.appendingPathComponent("Localizable.\(slot.fileType)"))
    }

    private func fileURL(installNamed name: String, slot: Slot) -> URL {
        Store.fileURL(in: directory.appendingPathComponent("installs/\(name)", isDirectory: true), slot: slot)
    }

    private static func relativePath(of slot: Slot) -> String {
        "\(slot.bundleId).bundle/\(slot.locale).lproj/Localizable.\(slot.fileType)"
    }

    private static func fileURL(in install: URL, slot: Slot) -> URL {
        install.appendingPathComponent(relativePath(of: slot))
    }

    private static func isSafeComponent(_ name: String) -> Bool {
        (1...64).contains(name.utf8.count)
            && name.utf8.allSatisfy { ($0 >= 48 && $0 <= 57) || ($0 >= 65 && $0 <= 90) || ($0 >= 97 && $0 <= 122) || $0 == 45 || $0 == 95 }
    }

    func activate(_ install: InstallRecord) throws {
        try requireOnDisk(install)
        var next = state
        // Same release again (a language change) must not displace the last other release: a launch-crash revert of
        // this checksum has to land on one that did not crash.
        if next.active?.checksum != install.checksum { next.previous = next.active }
        if next.active?.directory != install.directory { next.active = install }
        if next.pending?.directory == install.directory { next.pending = nil }
        try save(next)
        unrecordedInstalls.remove(install.directory)
    }

    func setPending(_ install: InstallRecord?) throws {
        if let install { try requireOnDisk(install) }
        var next = state
        next.pending = install
        try save(next)
        if let install { unrecordedInstalls.remove(install.directory) }
    }

    /// state.json must always name a complete directory.
    private func requireOnDisk(_ install: InstallRecord) throws {
        var isDirectory: ObjCBool = false
        let path = directory.appendingPathComponent("installs/\(install.directory)").path
        guard Store.isConsistent(install), FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue
        else { throw StoreError.missingInstall(install.directory) }
    }

    /// Directories the lookup snapshot reads from; cleanup never removes them while this process runs.
    func protect(_ install: InstallRecord) {
        protectedDirectories.insert(install.directory)
    }

    nonisolated func url(of install: InstallRecord) -> URL {
        directory.appendingPathComponent("installs/\(install.directory)", isDirectory: true)
    }

    nonisolated func fileURL(of install: InstallRecord, slot: Slot) -> URL? {
        let installURL = self.url(of: install)
        let url = Store.fileURL(in: installURL, slot: slot)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        // A case-insensitive volume answers for `EN` with the file stored as `en`; only the exact name is this slot's.
        guard let actual = try? url.resourceValues(forKeys: [.canonicalPathKey]).canonicalPath,
              let base = try? installURL.resourceValues(forKeys: [.canonicalPathKey]).canonicalPath else { return url }
        return actual == "\(base)/\(Store.relativePath(of: slot))" ? url : nil
    }

    /// Removes what nothing names; returns the removed paths relative to `<root>/Tarjim`.
    func cleanup() throws -> [String] {
        heldIndex = nil
        let tarjim = directory.deletingLastPathComponent().deletingLastPathComponent()
        var removed: [String] = []
        let keptInstalls = Set([state.active, state.previous, state.pending].compactMap { $0?.directory }).union(protectedDirectories).union(unrecordedInstalls)
        let keptStaging = state.stagingChecksum

        try remove(in: tarjim, from: tarjim, into: &removed) { $0 != "v1" }
        try remove(in: tarjim.appendingPathComponent("v1"), from: tarjim, into: &removed) { $0 != directory.lastPathComponent }
        // A crash between writing and renaming leaves these behind.
        try remove(in: directory, from: tarjim, into: &removed) { $0.hasPrefix(".state-") && $0.hasSuffix(".tmp") }
        try remove(in: directory.appendingPathComponent("installs"), from: tarjim, into: &removed) { !keptInstalls.contains($0) }
        let staging = directory.appendingPathComponent("staging")
        try remove(in: staging, from: tarjim, into: &removed) { $0 != keptStaging }
        if let keptStaging {
            try remove(in: staging.appendingPathComponent(keptStaging), from: tarjim, into: &removed) {
                $0.hasPrefix("build-") || ($0.hasPrefix(".") && $0.hasSuffix(".tmp"))
            }
        }
        return removed
    }

    private func entries(of directory: URL) throws -> [String] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
    }

    private func remove(in parent: URL, from base: URL, into removed: inout [String], where shouldRemove: (String) -> Bool) throws {
        for name in try entries(of: parent) where shouldRemove(name) {
            let url = parent.appendingPathComponent(name)
            try FileManager.default.removeItem(at: url)
            removed.append(String(url.standardizedFileURL.path.dropFirst(base.standardizedFileURL.path.count + 1)))
        }
    }
}
