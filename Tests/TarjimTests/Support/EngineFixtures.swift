import Foundation
import XCTest
@testable import Tarjim

final class TestValue<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value

    init(_ value: Value) { stored = value }

    var value: Value {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

/// One app on one device: a store root that survives `relaunch()`, a server, a clock, the user's languages.
final class AppProcess {
    let root: URL
    let server = DeliveryServer()
    let clock = TestClock()
    let preferences = TestValue<[String]>(["en-US"])
    let appLanguage = TestValue<String>("en")
    let app: AppResources
    private(set) var store: Store
    private(set) var snapshots = SnapshotHolder()
    private(set) var engine: Engine!

    init(_ test: XCTestCase) throws {
        root = try StoreFixtures.root(for: test)
        app = try LookupFixtures.app(for: test)
        store = try StoreFixtures.store(root)
        engine = try makeEngine()
    }

    /// A new process: fresh Store, snapshot and engine over the same files.
    func relaunch() throws {
        store = try StoreFixtures.store(root)
        snapshots = SnapshotHolder()
        engine = try makeEngine()
    }

    private func makeEngine() throws -> Engine {
        let client = DeliveryClient(endpoint: try DeliveryFixtures.endpoint(), identity: DeliveryFixtures.identity, transport: server)
        let clock = self.clock, preferences = self.preferences, appLanguage = self.appLanguage
        return Engine(EngineEnvironment(store: store, client: client, snapshots: snapshots,
                                        preferences: { preferences.value }, appLanguage: { appLanguage.value },
                                        fallbackLanguage: "en", now: { clock.now }, random: { 0 }))
    }

    /// What a lookup returns now, through the snapshot the engine swapped in.
    func string(_ key: String, bundle: TarjimBundle? = nil) -> String {
        let snapshots = self.snapshots
        return Resolver(app: app, defaultBundle: .namespace("default"), snapshot: { snapshots.current }).string(key, bundle: bundle)
    }

    var state: StoreState {
        get async { await store.state }
    }

    /// Collects the events the engine sends from now on.
    func recordUpdates() -> TestValue<[TarjimUpdate]> {
        let seen = TestValue<[TarjimUpdate]>([])
        let stream = engine.updates()
        Task {
            for await update in stream { seen.value.append(update) }
        }
        return seen
    }
}

enum EngineFixtures {
    static let titleSlot = Slot(bundleId: "ns7", locale: "en", fileType: "strings")

    /// release-1 with `app.title` (en) replaced.
    static func release(title: String, releaseId: Int) throws -> Release {
        try Release.one().changing(releaseId: releaseId, slots: [titleSlot: Data("\"app.title\" = \"\(title)\";".utf8)])
    }

    /// Lets the event stream's task run.
    static func settle() async {
        for _ in 0..<20 { await Task.yield() }
        try? await Task.sleep(nanoseconds: 20_000_000)
    }
}
