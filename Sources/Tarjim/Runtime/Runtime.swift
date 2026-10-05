import Foundation

/// One started SDK: the store, the engine, the reporter and the lookups, wired together. `Tarjim` holds one.
final class Runtime: Sendable {
    struct Environment: Sendable {
        let root: URL
        let transport: any Transport
        let appBundle: Bundle
        let preferences: @Sendable () -> [String]
        let appLanguage: @Sendable () -> String
        let now: @Sendable () -> Date
        let random: @Sendable () -> Double
        /// Waits between scheduled checks.
        let sleep: @Sendable (TimeInterval) async -> Void
        let sdkVersion: String
        let appVersion: String
        let osVersion: String
    }

    let configuration: TarjimConfiguration

    init(configuration: TarjimConfiguration, environment: Environment) throws {
        self.configuration = configuration
    }

    /// Launches the engine, opens the lookups, cleans up, and reports a revert. Once per instance.
    func start(foreground: Bool) async {}

    func string(_ key: String, bundle: TarjimBundle?) -> String {
        ""
    }

    func string(_ key: String, arguments: [CVarArg], bundle: TarjimBundle?) -> String {
        ""
    }

    var locale: Locale {
        Locale(identifier: "und")
    }

    /// One check now, with its report passed to the reporter.
    @discardableResult
    func checkNow() async -> CycleReport {
        CycleReport(outcome: .failed, nextCheckIn: -1)
    }

    func activatePendingUpdate() async -> Bool {
        false
    }

    func updates() -> AsyncStream<TarjimUpdate> {
        AsyncStream { $0.finish() }
    }

    /// The timer while the app is active: the launch delay, then a check every `nextCheckIn`; each wait also counts
    /// as foreground time. Stops after `iterations` checks (nil: until cancelled).
    func runSchedule(iterations: Int?) async {}

    /// The app's active localization; a storyboard-only app reports "Base", which is never a language.
    static func appLanguage(of bundle: Bundle) -> String {
        ""
    }
}
