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
        throw StoreError.notImplemented
    }

    func stagedObjects(checksum: String) -> Set<String> {
        []
    }

    func heldObject(hash: String, fileType: String) -> URL? {
        nil
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
