import Foundation

/// Routes a bundle's own string lookups through Tarjim: `NSLocalizedString`, storyboards and SwiftUI `Text("key")`
/// in the default environment all ask the main bundle. The bundle's class is replaced, at install time, by a subclass of
/// whatever class it has then, so an earlier patch by another library keeps working.
enum MainBundleProxy {
    /// Downloaded text for a key in a table, or nil to let the bundle answer as it would have.
    typealias Downloaded = @Sendable (_ key: String, _ table: String?) -> String?

    /// Patches `bundle` once; a second call does nothing and returns false.
    @discardableResult
    static func install(on bundle: Bundle, downloaded: @escaping Downloaded) -> Bool {
        false
    }

    static func isInstalled(on bundle: Bundle) -> Bool {
        false
    }

    /// The lookup as the bundle answered it before `install`; the app's own text, never Tarjim's, never recursing.
    static func original(_ bundle: Bundle, key: String, value: String?, table: String?) -> String {
        ""
    }
}

extension Resolver {
    /// Downloaded text only, unformatted, for a lookup Apple routed to the main bundle: a table named `nil` or
    /// `Localizable` is the default bundle; any other is the namespace of that name, else the custom bundle of that name.
    func downloaded(_ key: String, table: String?) -> String? {
        nil
    }
}
