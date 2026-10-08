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
    /// The interval the schedule follows after the latest answer of any kind, sent as `poll/`. Separate from
    /// `lastPollAfter`, which only a `meta` body sets; that stays the fallback when an answer names none.
    var pollInForce: Int?
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
    /// Seconds from `lastCheck` until `meta` is due again: `pollAfter`, a backoff, or a `Retry-After`.
    var checkInterval: Int?
    /// The ETag of the last `meta` 200, sent back as `If-None-Match`.
    var metaETag: String?
    /// The raw `meta` naming the newest install, kept for its signature (language changes, owed retries).
    var heldMeta: Data?
    /// The directory of an install activated but not yet proven: the app has not yet stayed in the foreground long enough.
    var probation: String?
    /// A random identifier for this install, created on first start when the app allows sending it.
    var installIdentifier: String?
    /// Rejected checksum to the report identity of why, kept so a report handler added in a later app version still
    /// hears a release that stays rejected.
    var rejectionReports: [String: String] = [:]

    init(sdkVersion: String) {
        self.sdkVersion = sdkVersion
    }

    /// Every field is optional on disk: another SDK version may have written fewer or more of them.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        formatVersion = try c.decodeIfPresent(Int.self, forKey: .formatVersion) ?? 0
        sdkVersion = try c.decodeIfPresent(String.self, forKey: .sdkVersion) ?? ""
        nextInstallNumber = try c.decodeIfPresent(Int.self, forKey: .nextInstallNumber) ?? 1
        lastCheck = try c.decodeIfPresent(Date.self, forKey: .lastCheck)
        lastPollAfter = try c.decodeIfPresent(Int.self, forKey: .lastPollAfter)
        pollInForce = try c.decodeIfPresent(Int.self, forKey: .pollInForce)
        backoffStep = try c.decodeIfPresent(Int.self, forKey: .backoffStep) ?? 0
        active = try c.decodeIfPresent(InstallRecord.self, forKey: .active)
        previous = try c.decodeIfPresent(InstallRecord.self, forKey: .previous)
        pending = try c.decodeIfPresent(InstallRecord.self, forKey: .pending)
        stagingChecksum = try c.decodeIfPresent(String.self, forKey: .stagingChecksum)
        launchCrashCount = try c.decodeIfPresent(Int.self, forKey: .launchCrashCount) ?? 0
        rejectedChecksums = try c.decodeIfPresent(Set<String>.self, forKey: .rejectedChecksums) ?? []
        badChecksums = try c.decodeIfPresent(Set<String>.self, forKey: .badChecksums) ?? []
        languageOverride = try c.decodeIfPresent(String.self, forKey: .languageOverride)
        deliveredReports = try c.decodeIfPresent(Set<String>.self, forKey: .deliveredReports) ?? []
        checkInterval = try c.decodeIfPresent(Int.self, forKey: .checkInterval)
        metaETag = try c.decodeIfPresent(String.self, forKey: .metaETag)
        heldMeta = try c.decodeIfPresent(Data.self, forKey: .heldMeta)
        probation = try c.decodeIfPresent(String.self, forKey: .probation)
        installIdentifier = try c.decodeIfPresent(String.self, forKey: .installIdentifier)
        rejectionReports = try c.decodeIfPresent([String: String].self, forKey: .rejectionReports) ?? [:]
    }

    func isCheckDue(now: Date, pollAfter: Int) -> Bool {
        guard let lastCheck else { return true }
        // A clock moved back must not stall polling until the old time comes round again.
        if lastCheck > now { return true }
        return now.timeIntervalSince(lastCheck) >= TimeInterval(pollAfter)
    }
}
