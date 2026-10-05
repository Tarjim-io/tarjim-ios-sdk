import Foundation

/// A condition the app may want to know about. Each is delivered once until it is seen resolved.
public struct TarjimReport: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        /// The release uses a manifest format this SDK version does not know; files already held stay in use.
        case unknownSchemaVersion(Int)
        /// The release has no iOS strings at all; files already held stay in use.
        case noStringsInRelease(checksum: String)
        /// The manifest failed its checksum in two cycles in a row.
        case manifestChecksumMismatch(checksum: String)
        /// A downloaded file failed its hash.
        case fileHashMismatch(hash: String)
        /// A file stayed unavailable for three cycles in a row; its slot keeps the previous text.
        case fileStillUnavailable(hash: String)
        /// The key or its binding is rejected (`code` as the server sent it); polling continues.
        case configuration(code: String)
        /// An update made the app crash at launch twice and was reverted.
        case revertedAfterLaunchCrashes(checksum: String)
    }

    public let kind: Kind
    /// Plain English, for a log line.
    public let message: String
}

/// Turns cycle results into reports, once per condition. Never touches the network.
actor Reporter {
    init(store: Store, handler: (@Sendable (TarjimReport) -> Void)?) {}

    func cycleFinished(_ report: CycleReport) async {}

    func reverted(checksum: String) async {}
}
