import Foundation

/// Everything a cycle talks to, injected.
struct CycleEnvironment: Sendable {
    let client: DeliveryClient
    let store: Store
    let now: @Sendable () -> Date
    /// In 0..<1; the jitter source.
    let random: @Sendable () -> Double
    /// The manifest's locale keys → the ones to serve, most specific first (chunk 5 wires LocaleSelector).
    let selectLocales: @Sendable ([String]) -> [String]
}

enum RejectionReason: Equatable, Sendable {
    /// C21: a `schemaVersion` this SDK does not know.
    case unknownSchema(Int)
    /// C22: no `strings` file anywhere in the manifest.
    case noStrings
    /// The bytes match `meta.checksum` but do not decode.
    case unreadable
}

enum CycleOutcome: Equatable, Sendable {
    /// `meta` is not due; nothing was requested.
    case notDue
    /// `meta` names what the device already has (a 304 included); owed slots were retried without result.
    case unchanged
    /// A new install was built and recorded as pending.
    case installed(InstallRecord)
    /// `meta` names the active install again while a newer one was pending: the pending one was dropped (a rollback).
    case discardedPending
    /// The manifest was kept out (C21, C22); its checksum is marked rejected.
    case rejected(checksum: String, RejectionReason)
    /// `meta` names a checksum already rejected or marked bad; nothing was fetched.
    case skipped
    /// 404 with nothing released to this stage yet.
    case unreleased
    /// The configuration class (§2): reported by chunk 5; polling continues.
    case configurationError(code: String)
    /// A 5xx, a 429, a network failure, an unreadable `meta` or a manifest that failed its checksum: backing off.
    case failed
}

struct CycleReport: Equatable, Sendable {
    let outcome: CycleOutcome
    /// When to run again, jitter included.
    let nextCheckIn: TimeInterval
}

/// §6.2's update cycle. Records what it builds as pending; activation is not its job.
actor UpdateCycle {
    private let environment: CycleEnvironment

    init(_ environment: CycleEnvironment) {
        self.environment = environment
    }

    /// One cycle if `meta` is due. Concurrent calls share one cycle.
    func run() async -> CycleReport {
        CycleReport(outcome: .failed, nextCheckIn: -1)
    }

    /// §6.2 step A: the selected locales changed; fetch what the newest manifest held lists for them.
    func languageChanged() async -> CycleReport {
        CycleReport(outcome: .failed, nextCheckIn: -1)
    }
}
