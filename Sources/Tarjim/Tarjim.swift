import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// The one started runtime of the process.
private final class RuntimeBox: @unchecked Sendable {
    private let lock = NSLock()
    private var runtime: Runtime?

    var current: Runtime? { lock.withLock { runtime } }

    /// Stores `candidate` unless a runtime is already held.
    func install(_ candidate: Runtime) -> Bool {
        lock.withLock {
            guard runtime == nil else { return false }
            runtime = candidate
            return true
        }
    }
}

/// The SDK. Call `start(_:)` once, early, from the main thread; everything else may be called from anywhere.
public enum Tarjim {
    private static let box = RuntimeBox()

    /// Cheap and synchronous: the work happens in the background. A second call is ignored.
    public static func start(_ configuration: TarjimConfiguration) {
        guard box.current == nil else { return }
        let runtime: Runtime
        do {
            runtime = try Runtime(configuration: configuration, environment: realEnvironment())
        } catch {
            Log.debug("start ignored: the host or the storage is unusable (\(error))")
            return
        }
        guard box.install(runtime) else { return }
        let foreground = isInForeground()
        observeLifecycle(of: runtime)
        Task.detached {
            await runtime.start(foreground: foreground)
            await runtime.runSchedule(iterations: nil)
        }
    }

    /// The downloaded text for `key`, else the app's own, else `key` itself. Never empty for a missing key.
    public static func string(_ key: String, bundle: TarjimBundle? = nil) -> String {
        if let runtime = box.current { return runtime.string(key, bundle: bundle) }
        return Bundle.main.localizedString(forKey: key, value: key, table: nil)
    }

    /// As `string(_:bundle:)`, formatted with the locale of the text that was found.
    public static func string(_ key: String, _ arguments: CVarArg..., bundle: TarjimBundle? = nil) -> String {
        if let runtime = box.current { return runtime.string(key, arguments: arguments, bundle: bundle) }
        let format = Bundle.main.localizedString(forKey: key, value: key, table: nil)
        return String(format: format, locale: Locale(identifier: Runtime.appLanguage(of: .main)), arguments: arguments)
    }

    /// The locale downloaded text is served in, or the app's language when none is.
    public static var locale: Locale {
        if let runtime = box.current { return runtime.locale }
        return Locale(identifier: Runtime.appLanguage(of: .main))
    }

    /// Shows a downloaded update now instead of at the next cold start. Returns whether there was one to show.
    public static func activatePendingUpdate() async -> Bool {
        guard let runtime = box.current else { return false }
        return await runtime.activatePendingUpdate()
    }

    /// A new stream per call: `.downloaded` and `.activated`, on a real change only.
    public static func updates() -> AsyncStream<TarjimUpdate> {
        guard let runtime = box.current else { return AsyncStream { $0.finish() } }
        return runtime.updates()
    }

    private static func realEnvironment() throws -> Runtime.Environment {
        let root = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil,
                                               create: true)
        let version = ProcessInfo.processInfo.operatingSystemVersion
        let info = Bundle.main.infoDictionary
        return Runtime.Environment(
            root: root, transport: URLSessionTransport(), appBundle: .main,
            preferences: { Locale.preferredLanguages }, appLanguage: { Runtime.appLanguage(of: .main) },
            now: { Date() }, random: { Double.random(in: 0..<1) },
            sleep: { seconds in
                guard seconds.isFinite, seconds > 0 else { return }
                try? await Task.sleep(nanoseconds: UInt64(min(seconds, 86_400) * 1_000_000_000))
            },
            sdkVersion: "0.1.0", appVersion: info?["CFBundleShortVersionString"] as? String ?? "0",
            osVersion: "\(version.majorVersion).\(version.minorVersion)")
    }

    private static func isInForeground() -> Bool {
        #if canImport(UIKit)
        let state: UIApplication.State = Thread.isMainThread
            ? MainActor.assumeIsolated { UIApplication.shared.applicationState }
            : DispatchQueue.main.sync { MainActor.assumeIsolated { UIApplication.shared.applicationState } }
        return state != .background
        #else
        return true
        #endif
    }

    private static func observeLifecycle(of runtime: Runtime) {
        #if canImport(UIKit)
        let resignedAt = LockedDate()
        let center = NotificationCenter.default
        center.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: nil) { _ in
            resignedAt.value = Date()
        }
        center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: nil) { _ in
            let away = resignedAt.value.map { Date().timeIntervalSince($0) } ?? 0
            Task { await runtime.didBecomeActive(afterBackground: away) }
        }
        #endif
    }
}

#if canImport(UIKit)
private final class LockedDate: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Date?

    var value: Date? {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}
#endif

public struct TarjimConfiguration: Sendable {
    public var projectId: Int
    public var apiKey: String
    public var host: URL
    /// The bundle a lookup without `bundle:` reads. Required, so a bundle added to the release later never changes
    /// what an existing lookup means.
    public var defaultBundle: TarjimBundle
    /// Served to a user whose language the release does not have, for the whole app, never per key.
    public var fallbackLanguage: String
    /// Called once per condition worth knowing about; nothing is sent anywhere.
    public var onReport: (@Sendable (TarjimReport) -> Void)?
    /// Sends a random per-install identifier with update checks so active installs can be counted.
    public var sendsInstallIdentifier: Bool = true
    /// Routes `NSLocalizedString`, storyboards and SwiftUI `Text` in the main bundle through Tarjim.
    public var interceptsMainBundle: Bool = true

    public init(projectId: Int, apiKey: String, host: URL, defaultBundle: TarjimBundle, fallbackLanguage: String) {
        self.projectId = projectId
        self.apiKey = apiKey
        self.host = host
        self.defaultBundle = defaultBundle
        self.fallbackLanguage = fallbackLanguage
    }
}
