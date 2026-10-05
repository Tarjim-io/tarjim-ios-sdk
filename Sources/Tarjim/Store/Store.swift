import Foundation

enum StoreError: Error, Equatable {
    case notImplemented
    /// A checksum, hash, file type, bundle id or locale that is not safe as a path component.
    case unsafeName(String)
    case hashMismatch
}

enum StoreIdentifier {
    static func make(host: URL, projectId: Int, apiKey: String) -> String {
        ""
    }
}

/// The only code that writes files. Takes verified bytes; never talks to the network.
actor Store {
    nonisolated let directory: URL
    private(set) var state: StoreState

    init(root: URL, identifier: String, sdkVersion: String) throws {
        directory = root.appendingPathComponent("Tarjim/v1/\(identifier)", isDirectory: true)
        state = StoreState(sdkVersion: sdkVersion)
    }

    func save(_ state: StoreState) throws {
        throw StoreError.notImplemented
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
