import Foundation

/// One file of one bundle in one locale.
struct Slot: Hashable, Codable, Sendable {
    let bundleId: String
    let locale: String
    let fileType: String
}

struct InstallRecord: Codable, Equatable, Sendable {
    /// `<n>-<checksum8>`, relative to `installs/`.
    let directory: String
    let checksum: String
    let releaseId: Int?
    /// Wanted slots not held with the manifest's hash: each holds the active install's file, or nothing.
    var owedSlots: Set<Slot>
}

/// What a new install is built from. The caller decides `wanted`; the Store only writes what `listed` names.
struct InstallPlan: Sendable {
    let checksum: String
    let releaseId: Int?
    let baseLocale: String?
    /// The manifest exactly as verified.
    let manifestRaw: Data
    /// Every slot the manifest lists, with its hash.
    let listed: [Slot: String]
    let wanted: Set<Slot>
}

/// The contents of `state.json`, the Store's only mutable file.
struct StoreState: Codable, Equatable, Sendable {
    static let currentFormatVersion = 1

    var formatVersion: Int = StoreState.currentFormatVersion
    var sdkVersion: String
    var nextInstallNumber: Int = 1
    var lastCheck: Date?
    var lastPollAfter: Int?
    var backoffStep: Int = 0
    var active: InstallRecord?
    var previous: InstallRecord?
    var pending: InstallRecord?
    var stagingChecksum: String?
    var launchCrashCount: Int = 0
    var rejectedChecksums: Set<String> = []
    var badChecksums: Set<String> = []
    var languageOverride: String?
    var deliveredReports: Set<String> = []

    init(sdkVersion: String) {
        self.sdkVersion = sdkVersion
    }

    func isCheckDue(now: Date, pollAfter: Int) -> Bool {
        guard let lastCheck else { return true }
        // A clock moved back must not stall polling until the old time comes round again.
        if lastCheck > now { return true }
        return now.timeIntervalSince(lastCheck) >= TimeInterval(pollAfter)
    }
}
