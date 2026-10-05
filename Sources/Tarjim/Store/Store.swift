import CryptoKit
import Foundation

enum StoreError: Error, Equatable {
    /// A checksum, hash, file type, bundle id or locale that is not safe as a path component.
    case unsafeName(String)
    case hashMismatch
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
        return loaded
    }

    func save(_ state: StoreState) throws {
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
        if let checksum = state.stagingChecksum, Store.isSafe(checksum: checksum) {
            let staged = stagingDirectory(checksum).appendingPathComponent("\(hash).\(fileType)")
            if stagedObjects(checksum: checksum).contains(staged.lastPathComponent) { return staged }
        }
        return installedFile(hash: hash, fileType: fileType)
    }

    /// Any install on disk, not just the ones state.json names: a rollback target may be none of them.
    private func installedFile(hash: String, fileType: String) -> URL? {
        for name in installDirectoryNames().reversed() {
            guard let manifest = readInstallManifest(named: name), !state.badChecksums.contains(manifest.checksum) else { continue }
            for (key, fileHash) in manifest.files where fileHash == hash {
                guard let slot = Store.slot(fromKey: key), slot.fileType == fileType else { continue }
                let url = fileURL(installNamed: name, slot: slot)
                if FileManager.default.fileExists(atPath: url.path) { return url }
            }
        }
        return nil
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
        let number = nextFreeInstallNumber(checksum: plan.checksum)
        let name = "\(number)-\(plan.checksum.prefix(8))"
        let build = stagingDirectory(plan.checksum).appendingPathComponent("build-\(number)", isDirectory: true)
        let fileManager = FileManager.default
        var owed: Set<Slot> = []
        var written: [String: String] = [:]
        do {
            try fileManager.createDirectory(at: build, withIntermediateDirectories: true)
            for slot in installableSlots(plan) {
                guard let hash = plan.listed[slot] else { continue }
                guard Store.isSafe(hash: hash) else { throw StoreError.unsafeName(hash) }
                let source = stagingSource(plan, slot: slot, hash: hash)
                if let source {
                    let data = try Data(contentsOf: source)
                    try writeFile(data, in: build, slot: slot, baseLocale: plan.baseLocale)
                    written[Store.key(for: slot)] = Store.sha256Hex(data)
                    continue
                }
                owed.insert(slot)
                if let (url, activeHash) = activeFile(for: slot) {
                    try writeFile(Data(contentsOf: url), in: build, slot: slot, baseLocale: plan.baseLocale)
                    written[Store.key(for: slot)] = activeHash
                }
            }
            try plan.manifestRaw.write(to: build.appendingPathComponent("manifest.json"))
            let record = InstallManifest(checksum: plan.checksum, releaseId: plan.releaseId, files: written)
            try JSONEncoder().encode(record).write(to: build.appendingPathComponent("install.json"))
            try fileManager.moveItem(at: build, to: directory.appendingPathComponent("installs/\(name)", isDirectory: true))
        } catch {
            try? fileManager.removeItem(at: build)
            throw error
        }
        InstallNumbers.record(number, for: directory)
        var next = state
        next.nextInstallNumber = number + 1
        try save(next)
        return InstallRecord(directory: name, checksum: plan.checksum, releaseId: plan.releaseId, owedSlots: owed)
    }

    /// Never reuses a path this process may have handed out, even if state.json has since gone back.
    private func nextFreeInstallNumber(checksum: String) -> Int {
        var number = max(state.nextInstallNumber, InstallNumbers.highest(for: directory) + 1)
        while FileManager.default.fileExists(atPath: directory.appendingPathComponent("installs/\(number)-\(checksum.prefix(8))").path) {
            number += 1
        }
        return number
    }

    /// Only Apple's two formats with names safe as path components; anything else is neither written nor owed.
    private func installableSlots(_ plan: InstallPlan) -> [Slot] {
        plan.wanted.intersection(plan.listed.keys)
            .filter { ($0.fileType == "strings" || $0.fileType == "stringsdict")
                && Store.isSafeComponent($0.bundleId) && Store.isSafeComponent($0.locale) }
            .sorted { Store.key(for: $0) < Store.key(for: $1) }
    }

    private func stagingSource(_ plan: InstallPlan, slot: Slot, hash: String) -> URL? {
        let staged = stagingDirectory(plan.checksum).appendingPathComponent("\(hash).\(slot.fileType)")
        if stagedObjects(checksum: plan.checksum).contains(staged.lastPathComponent) { return staged }
        return heldObject(hash: hash, fileType: slot.fileType)
    }

    private func activeFile(for slot: Slot) -> (URL, String)? {
        guard let active = state.active, !state.badChecksums.contains(active.checksum),
              let hash = readInstallManifest(named: active.directory)?.files[Store.key(for: slot)] else { return nil }
        let url = fileURL(installNamed: active.directory, slot: slot)
        return FileManager.default.fileExists(atPath: url.path) ? (url, hash) : nil
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

    private static func fileURL(in install: URL, slot: Slot) -> URL {
        install.appendingPathComponent("\(slot.bundleId).bundle/\(slot.locale).lproj/Localizable.\(slot.fileType)")
    }

    private static func isSafeComponent(_ name: String) -> Bool {
        (1...64).contains(name.utf8.count)
            && name.utf8.allSatisfy { ($0 >= 48 && $0 <= 57) || ($0 >= 65 && $0 <= 90) || ($0 >= 97 && $0 <= 122) || $0 == 45 || $0 == 95 }
    }

    func activate(_ install: InstallRecord) throws {
        var next = state
        if next.active?.directory != install.directory { next.previous = next.active }
        next.active = install
        if next.pending?.directory == install.directory { next.pending = nil }
        try save(next)
    }

    func setPending(_ install: InstallRecord?) throws {
        var next = state
        next.pending = install
        try save(next)
    }

    /// Directories the lookup snapshot reads from; cleanup never removes them while this process runs.
    func protect(_ install: InstallRecord) {
        protectedDirectories.insert(install.directory)
    }

    nonisolated func url(of install: InstallRecord) -> URL {
        directory.appendingPathComponent("installs/\(install.directory)", isDirectory: true)
    }

    nonisolated func fileURL(of install: InstallRecord, slot: Slot) -> URL? {
        let url = Store.fileURL(in: self.url(of: install), slot: slot)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Removes what nothing names; returns the removed paths relative to `<root>/Tarjim`.
    func cleanup() throws -> [String] {
        let tarjim = directory.deletingLastPathComponent().deletingLastPathComponent()
        var removed: [String] = []
        let keptInstalls = Set([state.active, state.previous, state.pending].compactMap { $0?.directory }).union(protectedDirectories)
        let keptStaging = state.stagingChecksum

        try remove(in: tarjim, keeping: ["v1"], from: tarjim, into: &removed)
        try remove(in: tarjim.appendingPathComponent("v1"), keeping: [directory.lastPathComponent], from: tarjim, into: &removed)
        try remove(in: directory.appendingPathComponent("installs"), keeping: keptInstalls, from: tarjim, into: &removed)
        let staging = directory.appendingPathComponent("staging")
        try remove(in: staging, keeping: keptStaging.map { [$0] } ?? [], from: tarjim, into: &removed)
        if let keptStaging {
            let builds = try entries(of: staging.appendingPathComponent(keptStaging)).filter { $0.hasPrefix("build-") }
            try remove(in: staging.appendingPathComponent(keptStaging), keeping: Set(try entries(of: staging.appendingPathComponent(keptStaging))).subtracting(builds),
                       from: tarjim, into: &removed)
        }
        return removed
    }

    private func entries(of directory: URL) throws -> [String] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
    }

    private func remove(in parent: URL, keeping kept: Set<String>, from base: URL, into removed: inout [String]) throws {
        for name in try entries(of: parent) where !kept.contains(name) {
            let url = parent.appendingPathComponent(name)
            try FileManager.default.removeItem(at: url)
            removed.append(String(url.standardizedFileURL.path.dropFirst(base.standardizedFileURL.path.count + 1)))
        }
    }
}
