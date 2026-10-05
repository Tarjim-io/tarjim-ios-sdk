import Foundation

/// What the app hears about, on a real change only.
public enum TarjimUpdate: Equatable, Sendable {
    /// A new release was downloaded; it is shown at the next cold start, on a return after a long time away, or when
    /// the app calls `activatePendingUpdate()`.
    case downloaded
    /// Lookups now read a different install.
    case activated
}

struct EngineEnvironment: Sendable {
    let store: Store
    let client: DeliveryClient
    let snapshots: SnapshotHolder
    /// The device's preferred languages, read at each selection.
    let preferences: @Sendable () -> [String]
    /// The app's active localization, read at each selection.
    let appLanguage: @Sendable () -> String
    let fallbackLanguage: String
    let now: @Sendable () -> Date
    let random: @Sendable () -> Double
}

/// Decides what lookups read: activation, the launch-crash revert, events and the snapshot swap.
actor Engine {
    /// Foreground time after which a newly activated install is trusted.
    static let probationSeconds: TimeInterval = 10
    /// Time in the background after which a pending install is shown on return.
    static let longBackgroundSeconds: TimeInterval = 3600

    private let environment: EngineEnvironment

    init(_ environment: EngineEnvironment) {
        self.environment = environment
    }

    /// Once per process; a second call does nothing. A launch the system makes in the background neither activates
    /// nor counts toward a revert.
    func launch(foreground: Bool) async {}

    /// Runs one update cycle if due and acts on its result.
    @discardableResult
    func check() async -> CycleReport {
        CycleReport(outcome: .failed, nextCheckIn: -1)
    }

    /// The selected locales may have changed: serve them if held, fetch them if the held manifest lists them.
    func selectionChanged() async {}

    /// Foreground time accumulated in this process.
    func foregroundElapsed(_ seconds: TimeInterval) async {}

    func didBecomeActive(afterBackground seconds: TimeInterval) async {}

    func activatePendingUpdate() async -> Bool {
        false
    }

    nonisolated func updates() -> AsyncStream<TarjimUpdate> {
        AsyncStream { $0.finish() }
    }

    /// The locales lookups currently serve, nil before the first install or when none matches.
    var selection: LocaleSelection? {
        nil
    }
}
