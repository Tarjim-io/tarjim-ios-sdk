import CryptoKit
import Foundation

enum StoreError: Error, Equatable {
    case notImplemented
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

/// The only code that writes files. Takes verified bytes; never talks to the network.
actor Store {
    nonisolated let directory: URL
    private(set) var state: StoreState

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
        return nil
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
        throw StoreError.notImplemented
    }

    func activate(_ install: InstallRecord) throws {
        throw StoreError.notImplemented
    }

    func setPending(_ install: InstallRecord?) throws {
        throw StoreError.notImplemented
    }

    /// Directories the lookup snapshot reads from; cleanup never removes them while this process runs.
    func protect(_ install: InstallRecord) {}

    nonisolated func url(of install: InstallRecord) -> URL {
        directory.appendingPathComponent("installs/\(install.directory)", isDirectory: true)
    }

    nonisolated func fileURL(of install: InstallRecord, slot: Slot) -> URL? {
        nil
    }

    /// Removes what nothing names; returns the removed paths relative to `<root>/Tarjim`.
    func cleanup() throws -> [String] {
        throw StoreError.notImplemented
    }
}
