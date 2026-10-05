import Foundation

/// The SDK. Call `start(_:)` once, early, from the main thread; everything else may be called from anywhere.
public enum Tarjim {
    /// Cheap and synchronous: the work happens in the background. A second call is ignored.
    public static func start(_ configuration: TarjimConfiguration) {}

    /// The downloaded text for `key`, else the app's own, else `key` itself. Never empty for a missing key.
    public static func string(_ key: String, bundle: TarjimBundle? = nil) -> String {
        key
    }

    /// As `string(_:bundle:)`, formatted with the locale of the text that was found.
    public static func string(_ key: String, _ arguments: CVarArg..., bundle: TarjimBundle? = nil) -> String {
        key
    }

    /// The locale downloaded text is served in, or the app's language when none is.
    public static var locale: Locale {
        Locale.current
    }

    /// Shows a downloaded update now instead of at the next cold start. Returns whether there was one to show.
    public static func activatePendingUpdate() async -> Bool {
        false
    }

    /// A new stream per call: `.downloaded` and `.activated`, on a real change only.
    public static func updates() -> AsyncStream<TarjimUpdate> {
        AsyncStream { $0.finish() }
    }
}

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
