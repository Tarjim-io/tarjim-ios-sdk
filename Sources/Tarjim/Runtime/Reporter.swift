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

    public init(kind: Kind, message: String) {
        self.kind = kind
        self.message = message
    }
}

/// Turns cycle results into reports, once per condition. Never touches the network.
actor Reporter {
    private let store: Store
    private let handler: (@Sendable (TarjimReport) -> Void)?
    /// Identities written to the log in this process.
    private var logged: Set<String> = []
    private var mismatchRuns: [String: Int] = [:]
    private var owedRuns: [String: Int] = [:]
    /// Identities being delivered; a second raise of one meanwhile would pass the delivered check too.
    private var inFlight: Set<String> = []

    init(store: Store, handler: (@Sendable (TarjimReport) -> Void)?) {
        self.store = store
        self.handler = handler
    }

    func cycleFinished(_ report: CycleReport) async {
        let signals = report.signals
        var owed: Set<String>?
        var mismatches: Set<String> = []
        var fileMismatches: [String] = []
        var answered = false
        var stillRejected: [String] = []
        for signal in signals {
            switch signal {
            case .metaAnswered: answered = true
            case let .owed(hashes): owed = hashes
            case let .manifestChecksumMismatch(checksum): mismatches.insert(checksum)
            case let .fileHashMismatch(hash): fileMismatches.append(hash)
            case let .stillRejected(checksum): stillRejected.append(checksum)
            case let .installed(schemaVersion, hasStrings, _):
                if schemaVersion == 1 { await clear(prefix: "schema:") }
                if hasStrings { await clear(prefix: "no-strings:") }
            }
        }
        if answered { await clear(prefix: "config:") }

        switch report.outcome {
        case let .rejected(checksum, .unknownSchema(version)):
            await remember(rejection: checksum, as: "schema:\(version)")
            await raise("schema:\(version)")
        case let .rejected(checksum, .noStrings):
            await remember(rejection: checksum, as: "no-strings:\(checksum)")
            await raise("no-strings:\(checksum)")
        case let .configurationError(code):
            await raise("config:\(code)", .configuration(code: code), "The key or its binding is rejected: \(code).")
        default:
            break
        }
        if !stillRejected.isEmpty {
            let held = await store.state.rejectionReports
            for checksum in stillRejected { if let identity = held[checksum] { await raise(identity) } }
        }

        // A cycle that never reached the server says nothing about a manifest.
        if answered {
            for checksum in mismatchRuns.keys where !mismatches.contains(checksum) { mismatchRuns[checksum] = nil }
            for checksum in await identities(prefix: "checksum:") where !mismatches.contains(checksum) {
                await clear(identity: "checksum:\(checksum)")
            }
        }
        for checksum in mismatches.sorted() {
            let run = (mismatchRuns[checksum] ?? 0) + 1
            mismatchRuns[checksum] = run
            if run == 2 {
                await raise("checksum:\(checksum)", .manifestChecksumMismatch(checksum: checksum),
                            "The manifest \(checksum) failed its checksum in two cycles in a row.")
            }
        }

        for hash in fileMismatches {
            await raise("hash:\(hash)", .fileHashMismatch(hash: hash), "The downloaded file \(hash) failed its hash.")
        }
        guard let owed else { return }
        // A cycle whose own download failed the hash again has not resolved it, even though it built nothing to owe.
        for hash in await identities(prefix: "hash:") where !owed.contains(hash) && !fileMismatches.contains(hash) {
            await clear(identity: "hash:\(hash)")
        }
        // Also what an earlier process delivered: this one never counted it.
        for hash in Set(owedRuns.keys).union(await identities(prefix: "owed:")) where !owed.contains(hash) {
            owedRuns[hash] = nil
            await clear(identity: "owed:\(hash)")
        }
        for hash in owed.sorted() {
            let run = (owedRuns[hash] ?? 0) + 1
            owedRuns[hash] = run
            if run == 3 {
                await raise("owed:\(hash)", .fileStillUnavailable(hash: hash),
                            "The file \(hash) stayed unavailable for three cycles in a row.")
            }
        }
    }

    func reverted(checksum: String) async {
        await raise("revert:\(checksum)", .revertedAfterLaunchCrashes(checksum: checksum),
                    "The update \(checksum) made the app crash at launch twice and was reverted.")
    }

    // MARK: Delivery

    /// Raises a rejection by the identity stored for it.
    private func raise(_ identity: String) async {
        if identity.hasPrefix("schema:"), let version = Int(identity.dropFirst("schema:".count)) {
            await raise(identity, .unknownSchemaVersion(version),
                        "The release uses manifest format \(version), which this SDK does not know.")
        } else if identity.hasPrefix("no-strings:") {
            let checksum = String(identity.dropFirst("no-strings:".count))
            await raise(identity, .noStringsInRelease(checksum: checksum), "The release \(checksum) has no iOS strings.")
        }
    }

    /// Written whether or not a handler exists, so one added in a later app version still hears it.
    private func remember(rejection checksum: String, as identity: String) async {
        guard await store.state.rejectionReports[checksum] != identity else { return }
        try? await store.update { $0.rejectionReports[checksum] = identity }
    }

    private func raise(_ identity: String, _ kind: TarjimReport.Kind, _ message: String) async {
        // Marked before the first suspension: a concurrent raise of the same identity would otherwise also find it
        // undelivered.
        guard inFlight.insert(identity).inserted else { return }
        defer { inFlight.remove(identity) }
        let delivered = await store.state.deliveredReports.contains(identity)
        if !delivered, logged.insert(identity).inserted { Log.debug(message) }
        guard let handler, !delivered else { return }
        handler(TarjimReport(kind: kind, message: message))
        try? await store.update { $0.deliveredReports.insert(identity) }
    }

    private func clear(identity: String) async {
        logged.remove(identity)
        guard await store.state.deliveredReports.contains(identity) else { return }
        try? await store.update { $0.deliveredReports.remove(identity) }
    }

    private func clear(prefix: String) async {
        let held = await store.state.deliveredReports.filter { $0.hasPrefix(prefix) }
        for identity in logged.filter({ $0.hasPrefix(prefix) }).union(held) { await clear(identity: identity) }
    }

    /// The values of the identities of one kind that are recorded as delivered or logged in this process.
    private func identities(prefix: String) async -> [String] {
        let held = await store.state.deliveredReports
        return held.union(logged).filter { $0.hasPrefix(prefix) }.map { String($0.dropFirst(prefix.count)) }
    }
}
