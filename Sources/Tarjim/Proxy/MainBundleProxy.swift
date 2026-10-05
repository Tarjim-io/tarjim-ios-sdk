import Foundation
import ObjectiveC

/// Routes a bundle's own string lookups through Tarjim: `NSLocalizedString`, storyboards and SwiftUI `Text("key")`
/// in the default environment all ask the main bundle. The bundle's class is replaced, at install time, by a subclass of
/// whatever class it has then, so an earlier patch by another library keeps working.
enum MainBundleProxy {
    /// A downloaded answer and the locale folder it came from, which can also answer the attributed lookup.
    struct DownloadedText {
        let value: String
        let source: Bundle
    }

    /// What the resolver decided for a lookup.
    enum Answer {
        case downloaded(DownloadedText)
        /// The app's own text, already read: asking the original again would reach it a second time.
        case app(String)
        /// The app has no text and neither has the download; Apple's `value`-or-key answer applies.
        case missed
    }

    /// The answer for a key in a table, or nil to let the bundle answer as it would have.
    typealias Downloaded = @Sendable (_ key: String, _ table: String?) -> Answer?

    private typealias StringLookup = @convention(c) (AnyObject, Selector, NSString, NSString?, NSString?) -> NSString
    private typealias AttributedLookup = @convention(c) (AnyObject, Selector, NSString, NSString?, NSString?) -> NSAttributedString

    private static let stringSelector = NSSelectorFromString("localizedStringForKey:value:table:")
    private static let attributedSelector = NSSelectorFromString("localizedAttributedStringForKey:value:table:")
    private static let classSelector = NSSelectorFromString("class")

    private final class State: @unchecked Sendable {
        let downloaded: Downloaded
        /// The class the bundle had before install; its implementations are looked up per call.
        let base: AnyClass
        let subclass: AnyClass

        init(downloaded: @escaping Downloaded, base: AnyClass, subclass: AnyClass) {
            self.downloaded = downloaded
            self.base = base
            self.subclass = subclass
        }
    }

    // The key's address is its identity; the value is never read.
    nonisolated(unsafe) private static var stateKey: UInt8 = 0
    private static let lock = NSLock()
    // One subclass per base class: registering a second class of the same name would fail.
    nonisolated(unsafe) private static var subclasses: [ObjectIdentifier: AnyClass] = [:]

    /// Patches `bundle` once; a second call does nothing and returns false.
    @discardableResult
    static func install(on bundle: Bundle, downloaded: @escaping Downloaded) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !isInstalled(on: bundle), let base = object_getClass(bundle),
              class_getInstanceMethod(base, stringSelector) != nil else { return false }
        // KVO and similar isa-swizzles keep state in indexed ivars of their class that a subclass of it lacks.
        guard let reported = bundle.perform(classSelector)?.takeUnretainedValue(), reported === base else { return false }
        let subclass: AnyClass
        if let known = subclasses[ObjectIdentifier(base)] {
            subclass = known
        } else {
            guard let made = makeSubclass(of: base) else { return false }
            subclasses[ObjectIdentifier(base)] = made
            subclass = made
        }
        objc_setAssociatedObject(bundle, &stateKey, State(downloaded: downloaded, base: base, subclass: subclass),
                                 .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        object_setClass(bundle, subclass)
        return true
    }

    /// True while the bundle's class is ours or a subclass of it; another library's later swap ends that.
    static func isInstalled(on bundle: Bundle) -> Bool {
        installedState(of: bundle) != nil
    }

    /// The lookup as the bundle answered it before `install`; the app's own text, never Tarjim's, never recursing.
    static func original(_ bundle: Bundle, key: String, value: String?, table: String?) -> String {
        guard let state = installedState(of: bundle) else {
            return bundle.localizedString(forKey: key, value: value, table: table)
        }
        return callOriginal(state, bundle, key, value, table)
    }

    private static func state(of bundle: AnyObject) -> State? {
        objc_getAssociatedObject(bundle, &stateKey) as? State
    }

    private static func installedState(of bundle: Bundle) -> State? {
        guard let state = state(of: bundle) else { return nil }
        var current: AnyClass? = object_getClass(bundle)
        while let candidate = current {
            if candidate === state.subclass { return state }
            current = class_getSuperclass(candidate)
        }
        return nil
    }

    private static func callOriginal(_ state: State, _ bundle: AnyObject, _ key: String, _ value: String?,
                                     _ table: String?) -> String {
        guard let imp = class_getMethodImplementation(state.base, stringSelector) else { return value ?? key }
        let call = unsafeBitCast(imp, to: StringLookup.self)
        return call(bundle, stringSelector, key as NSString, value as NSString?, table as NSString?) as String
    }

    private static func applesFallback(_ key: NSString, _ value: NSString?) -> String {
        if let value, value.length > 0 { return value as String }
        return key as String
    }

    private static func makeSubclass(of base: AnyClass) -> AnyClass? {
        guard let subclass = objc_allocateClassPair(base, "Tarjim_" + NSStringFromClass(base), 0) else { return nil }

        let string: @convention(block) (AnyObject, NSString, NSString?, NSString?) -> NSString = { bundle, key, value, table in
            guard let state = state(of: bundle) else { return ((value as String?) ?? (key as String)) as NSString }
            switch state.downloaded(key as String, table as String?) {
            case .downloaded(let hit): return hit.value as NSString
            case .app(let text): return text as NSString
            case .missed: return applesFallback(key, value) as NSString
            case nil: break
            }
            return callOriginal(state, bundle, key as String, value as String?, table as String?) as NSString
        }
        class_addMethod(subclass, stringSelector, imp_implementationWithBlock(string), "@@:@@@")

        if class_getInstanceMethod(base, attributedSelector) != nil {
            let attributed: @convention(block) (AnyObject, NSString, NSString?, NSString?) -> NSAttributedString = {
                bundle, key, value, table in
                guard let state = state(of: bundle) else { return NSAttributedString(string: (value as String?) ?? (key as String)) }
                switch state.downloaded(key as String, table as String?) {
                case .downloaded(let hit):
                    // Apple's own lookup on the locale folder keeps plural rules, language and markdown.
                    if let imp = class_getMethodImplementation(object_getClass(hit.source), attributedSelector) {
                        let call = unsafeBitCast(imp, to: AttributedLookup.self)
                        return call(hit.source, attributedSelector, key, nil, nil)
                    }
                    return NSAttributedString(string: hit.value)
                case .missed: return NSAttributedString(string: applesFallback(key, value))
                case .app, nil: break
                }
                guard let imp = class_getMethodImplementation(state.base, attributedSelector) else {
                    return NSAttributedString(string: (value as String?) ?? (key as String))
                }
                return unsafeBitCast(imp, to: AttributedLookup.self)(bundle, attributedSelector, key, value, table)
            }
            class_addMethod(subclass, attributedSelector, imp_implementationWithBlock(attributed), "@@:@@@")
        }
        objc_registerClassPair(subclass)
        return subclass
    }
}

extension Resolver {
    /// Downloaded text only, unformatted, for a lookup Apple routed to the main bundle: a table named `nil` or
    /// `Localizable` is the default bundle; any other is the namespace of that name, else the custom bundle of that name.
    func downloaded(_ key: String, table: String?) -> MainBundleProxy.Answer? {
        let snapshot = snapshot()
        guard let selection = snapshot.selection else { return nil }
        // As in `string`: for a fallback selection the app's own text comes before the download.
        var appMissed = false
        if selection.kind == .fallback {
            let own = MainBundleProxy.original(app.bundle, key: key, value: Self.sentinel, table: table)
            if own != Self.sentinel { return .app(own) }
            appMissed = true
        }
        let bundle: TarjimBundle
        if let table, table != "Localizable" {
            bundle = BundleDirectory.id(for: .namespace(table), in: snapshot.entries) != nil ? .namespace(table) : .custom(table)
        } else {
            bundle = defaultBundle
        }
        let hit = BundleDirectory.id(for: bundle, in: snapshot.entries).flatMap {
            ota(raw: key, snapshot: snapshot, id: $0, locales: selection.locales)
        }
        if let hit { return .downloaded(hit) }
        return appMissed ? .missed : nil
    }
}
