import Foundation
import ObjectiveC

/// Routes a bundle's own string lookups through Tarjim: `NSLocalizedString`, storyboards and SwiftUI `Text("key")`
/// in the default environment all ask the main bundle. The bundle's class is replaced, at install time, by a subclass of
/// whatever class it has then, so an earlier patch by another library keeps working.
enum MainBundleProxy {
    /// Downloaded text for a key in a table, or nil to let the bundle answer as it would have.
    typealias Downloaded = @Sendable (_ key: String, _ table: String?) -> String?

    private typealias StringLookup = @convention(c) (AnyObject, Selector, NSString, NSString?, NSString?) -> NSString
    private typealias AttributedLookup = @convention(c) (AnyObject, Selector, NSString, NSString?, NSString?) -> NSAttributedString

    private static let stringSelector = NSSelectorFromString("localizedStringForKey:value:table:")
    private static let attributedSelector = NSSelectorFromString("localizedAttributedStringForKey:value:table:")

    /// What one patched subclass calls on a miss: the implementations of the class it replaced.
    private final class Originals: @unchecked Sendable {
        let string: IMP
        let attributed: IMP?

        init(string: IMP, attributed: IMP?) {
            self.string = string
            self.attributed = attributed
        }
    }

    private final class State: @unchecked Sendable {
        let downloaded: Downloaded
        let originals: Originals

        init(downloaded: @escaping Downloaded, originals: Originals) {
            self.downloaded = downloaded
            self.originals = originals
        }
    }

    // The key's address is its identity; the value is never read.
    nonisolated(unsafe) private static var stateKey: UInt8 = 0
    private static let lock = NSLock()
    // One subclass per base class: registering a second class of the same name would fail.
    nonisolated(unsafe) private static var subclasses: [ObjectIdentifier: (AnyClass, Originals)] = [:]

    /// Patches `bundle` once; a second call does nothing and returns false.
    @discardableResult
    static func install(on bundle: Bundle, downloaded: @escaping Downloaded) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard state(of: bundle) == nil else { return false }
        guard let base = object_getClass(bundle) else { return false }
        let (subclass, originals): (AnyClass, Originals)
        if let known = subclasses[ObjectIdentifier(base)] {
            (subclass, originals) = known
        } else {
            guard let made = makeSubclass(of: base) else { return false }
            subclasses[ObjectIdentifier(base)] = made
            (subclass, originals) = made
        }
        objc_setAssociatedObject(bundle, &stateKey, State(downloaded: downloaded, originals: originals),
                                 .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        object_setClass(bundle, subclass)
        return true
    }

    static func isInstalled(on bundle: Bundle) -> Bool {
        state(of: bundle) != nil
    }

    /// The lookup as the bundle answered it before `install`; the app's own text, never Tarjim's, never recursing.
    static func original(_ bundle: Bundle, key: String, value: String?, table: String?) -> String {
        guard let originals = state(of: bundle)?.originals else {
            return bundle.localizedString(forKey: key, value: value, table: table)
        }
        return callOriginal(originals, bundle, key, value, table)
    }

    private static func state(of bundle: Bundle) -> State? {
        objc_getAssociatedObject(bundle, &stateKey) as? State
    }

    private static func callOriginal(_ originals: Originals, _ bundle: AnyObject, _ key: String, _ value: String?,
                                     _ table: String?) -> String {
        let call = unsafeBitCast(originals.string, to: StringLookup.self)
        return call(bundle, stringSelector, key as NSString, value as NSString?, table as NSString?) as String
    }

    private static func makeSubclass(of base: AnyClass) -> (AnyClass, Originals)? {
        guard class_getInstanceMethod(base, stringSelector) != nil,
              let stringIMP = class_getMethodImplementation(base, stringSelector),
              let subclass = objc_allocateClassPair(base, "Tarjim_" + NSStringFromClass(base), 0) else { return nil }
        let originals = Originals(
            string: stringIMP,
            attributed: class_getInstanceMethod(base, attributedSelector) == nil
                ? nil : class_getMethodImplementation(base, attributedSelector))

        let string: @convention(block) (AnyObject, NSString, NSString?, NSString?) -> NSString = { bundle, key, value, table in
            if let bundle = bundle as? Bundle, let hit = state(of: bundle)?.downloaded(key as String, table as String?) {
                return hit as NSString
            }
            return callOriginal(originals, bundle, key as String, value as String?, table as String?) as NSString
        }
        class_addMethod(subclass, stringSelector, imp_implementationWithBlock(string), "@@:@@@")

        if let original = originals.attributed {
            let attributed: @convention(block) (AnyObject, NSString, NSString?, NSString?) -> NSAttributedString = {
                bundle, key, value, table in
                if let bundle = bundle as? Bundle, let hit = state(of: bundle)?.downloaded(key as String, table as String?) {
                    return NSAttributedString(string: hit)
                }
                let call = unsafeBitCast(original, to: AttributedLookup.self)
                return call(bundle, attributedSelector, key, value, table)
            }
            class_addMethod(subclass, attributedSelector, imp_implementationWithBlock(attributed), "@@:@@@")
        }
        objc_registerClassPair(subclass)
        return (subclass, originals)
    }
}

extension Resolver {
    /// Downloaded text only, unformatted, for a lookup Apple routed to the main bundle: a table named `nil` or
    /// `Localizable` is the default bundle; any other is the namespace of that name, else the custom bundle of that name.
    func downloaded(_ key: String, table: String?) -> String? {
        let snapshot = snapshot()
        guard let selection = snapshot.selection else { return nil }
        let bundle: TarjimBundle
        if let table, table != "Localizable" {
            bundle = BundleDirectory.id(for: .namespace(table), in: snapshot.entries) != nil ? .namespace(table) : .custom(table)
        } else {
            bundle = defaultBundle
        }
        guard let id = BundleDirectory.id(for: bundle, in: snapshot.entries) else { return nil }
        return ota(raw: key, snapshot: snapshot, id: id, locales: selection.locales)
    }
}
