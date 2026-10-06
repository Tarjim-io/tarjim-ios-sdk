import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// The one started runtime of the process, and the streams opened before it existed.
private final class RuntimeBox: @unchecked Sendable {
    private let lock = NSLock()
    private var runtime: Runtime?
    private var waiting: [AsyncStream<TarjimUpdate>.Continuation] = []

    var current: Runtime? { lock.withLock { runtime } }

    /// Stores `candidate` unless a runtime is already held, and connects the streams that were waiting for it.
    func install(_ candidate: Runtime) -> Bool {
        let waiters: [AsyncStream<TarjimUpdate>.Continuation]? = lock.withLock {
            guard runtime == nil else { return nil }
            runtime = candidate
            defer { waiting = [] }
            return waiting
        }
        guard let waiters else { return false }
        for continuation in waiters { RuntimeBox.forward(candidate, to: continuation) }
        return true
    }

    private static func forward(_ runtime: Runtime, to continuation: AsyncStream<TarjimUpdate>.Continuation) {
        let events = runtime.updates()
        let task = Task { for await update in events { continuation.yield(update) } }
        continuation.onTermination = { _ in task.cancel() }
    }

    /// A stream that hears the runtime's events once it exists.
    func updates() -> AsyncStream<TarjimUpdate> {
        let (stream, continuation) = AsyncStream<TarjimUpdate>.makeStream()
        let ready = lock.withLock { () -> Runtime? in
            if runtime == nil { waiting.append(continuation) }
            return runtime
        }
        guard let ready else { return stream }
        RuntimeBox.forward(ready, to: continuation)
        return stream
    }
}

/// The SDK. Call `start(_:)` once, early, from the main thread; everything else may be called from anywhere.
public enum Tarjim {
    private static let box = RuntimeBox()

    /// Starts the SDK: call it once, early, before the first lookup, on the main thread. There it waits up to
    /// `Runtime.launchBound` (one second) while the stored release is loaded, so the first lookup already serves it, and
    /// a release downloaded earlier is shown from the first screen; past the bound, lookups catch up in the background.
    /// Nothing waits for the network. Called off the main thread it returns at once and does its work in the
    /// background. The main bundle is routed through Tarjim before it returns. A second call is ignored. An invalid `host` is a programmer error: it stops a debug build with an
    /// assertion and is ignored in a release build.
    public static func start(_ configuration: TarjimConfiguration) {
        guard box.current == nil else { return }
        let environment: Runtime.Environment
        do {
            environment = try realEnvironment()
        } catch {
            Log.debug("Tarjim.start ignored: the storage is unusable (\(error))")
            return
        }
        let runtime: Runtime
        do {
            runtime = try Runtime(configuration: configuration, environment: environment)
        } catch {
            let message = "Tarjim.start ignored: \(error)"
            Log.debug(message)
            if error as? DeliveryEndpoint.Error == .invalidHost {
                assertionFailure("Tarjim.start ignored: the host is not a valid server address")
            }
            return
        }
        guard box.install(runtime) else { return }
        observeLifecycle(of: runtime)
        if Thread.isMainThread {
            let active = isActiveOnMainThread()
            _ = runtime.launch(foreground: active, waitingUpTo: Runtime.launchBound)
            if active {
                Task.detached {
                    await runtime.waitForLaunch()
                    await runtime.becameActive()
                }
            }
        } else {
            Task.detached {
                let active = await isActive()
                await runtime.start(foreground: active)
                if active { await runtime.becameActive() }
            }
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

    /// Serves Tarjim text in `identifier` (a language the release has, such as "ar" or "pt-BR") instead of the app's
    /// language, and remembers the choice across launches; `nil` follows the app's language again. A language the release
    /// does not have is ignored — and kept, so it applies once a release adds it. Only Tarjim text changes: layout
    /// direction, system text and number formats stay with the app's language. Call it any time after `start`, including
    /// immediately; the choice is remembered across launches.
    public static func setLanguage(_ identifier: String?) async {
        await box.current?.setLanguage(identifier)
    }

    /// Shows a downloaded update now instead of at the next cold start. Returns whether there was one to show.
    public static func activatePendingUpdate() async -> Bool {
        guard let runtime = box.current else { return false }
        return await runtime.activatePendingUpdate()
    }

    /// A new stream per call: `.downloaded` and `.activated`, on a real change only. A stream opened before `start`
    /// receives events once it starts.
    public static func updates() -> AsyncStream<TarjimUpdate> {
        box.updates()
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

    /// Not in the background; read on the main actor, which `start` never blocks on.
    private static func isActive() async -> Bool {
        #if canImport(UIKit)
        await MainActor.run { UIApplication.shared.applicationState != .background }
        #else
        true
        #endif
    }

    private static func isActiveOnMainThread() -> Bool {
        #if canImport(UIKit)
        MainActor.assumeIsolated { UIApplication.shared.applicationState != .background }
        #else
        true
        #endif
    }

    private static func observeLifecycle(of runtime: Runtime) {
        #if canImport(UIKit)
        let center = NotificationCenter.default
        center.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: nil) { _ in
            runtime.noteResignedActive()
        }
        center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: nil) { _ in
            runtime.noteBecameActive()
        }
        #endif
    }
}

public struct TarjimConfiguration: Sendable {
    /// The Tarjim project whose released translations are downloaded.
    public var projectId: Int
    /// The project's API key. It is sent only in a request header, and only to `host`.
    public var apiKey: String
    /// The Tarjim delivery server, an `https` address such as `https://example.com`.
    public var host: URL
    /// The bundle a lookup without `bundle:` reads. Required, so a bundle added to the release later never changes
    /// what an existing lookup means.
    public var defaultBundle: TarjimBundle
    /// Served to a user whose language the release does not have, for the whole app, never per key.
    public var fallbackLanguage: String
    /// Called once per condition worth knowing about, on a background thread; nothing is sent anywhere. A condition
    /// that goes away and returns is called again.
    public var onReport: (@Sendable (TarjimReport) -> Void)?
    /// Sends a random identifier with update checks so active installs can be counted. It is a UUID the SDK stores
    /// itself: a reinstall and a change of API key each get a new one. On by default; off sends none.
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

/// The key is never shown, whichever way the configuration is printed.
extension TarjimConfiguration: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var description: String {
        "TarjimConfiguration(projectId: \(projectId), apiKey: <redacted>, host: \(host), defaultBundle: \(defaultBundle), "
            + "fallbackLanguage: \(fallbackLanguage))"
    }

    public var debugDescription: String { description }

    public var customMirror: Mirror {
        Mirror(self, children: [
            "projectId": projectId, "apiKey": "<redacted>", "host": host, "defaultBundle": defaultBundle,
            "fallbackLanguage": fallbackLanguage, "sendsInstallIdentifier": sendsInstallIdentifier,
            "interceptsMainBundle": interceptsMainBundle,
        ])
    }
}
