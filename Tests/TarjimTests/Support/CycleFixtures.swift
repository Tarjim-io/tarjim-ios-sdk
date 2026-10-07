import Foundation
import XCTest
@testable import Tarjim

/// A clock the test moves by hand.
final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current = Date(timeIntervalSince1970: 1_790_000_000)

    private var elapsed: TimeInterval = 0

    var now: Date { lock.withLock { current } }
    /// Time the device has run; it never goes back, whatever the wall clock does.
    var uptime: TimeInterval { lock.withLock { elapsed } }

    /// Time passing. A negative value is the wall clock set back; uptime stays.
    func advance(_ seconds: TimeInterval) {
        lock.withLock {
            current = current.addingTimeInterval(seconds)
            if seconds > 0 { elapsed += seconds }
        }
    }

    /// The user changing the date: only the wall clock moves.
    func jump(_ seconds: TimeInterval) {
        lock.withLock { current = current.addingTimeInterval(seconds) }
    }
}

/// Holds the first request it sees until released, so a test can start a second call while the first is in flight.
final class Gate: @unchecked Sendable {
    private let lock = NSLock()
    private var armed = true
    private let entered = DispatchSemaphore(value: 0)
    private let opened = DispatchSemaphore(value: 0)

    /// Call from the server's hook: blocks the first caller only.
    func hold() {
        let first = lock.withLock { () -> Bool in
            defer { armed = false }
            return armed
        }
        guard first else { return }
        entered.signal()
        opened.wait()
    }

    /// Returns once the first request is being held, then gives the second call time to reach the actor.
    func waitUntilHeld() async throws {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.global().async { [entered] in
                entered.wait()
                continuation.resume()
            }
        }
    }

    func open() {
        opened.signal()
    }
}

/// The locales the "user" wants; the cycle serves those the manifest lists, in this order.
final class TestSelection: @unchecked Sendable {
    private let lock = NSLock()
    private var wanted: [String]

    init(_ wanted: [String]) { self.wanted = wanted }

    func set(_ locales: [String]) { lock.withLock { wanted = locales } }

    func select(_ available: [String]) -> [String] {
        lock.withLock { wanted.filter(available.contains) }
    }
}

/// One device: a store root, a server, a clock. `cycle()` builds a fresh `UpdateCycle` over the same store, as a relaunch would.
final class Device {
    let root: URL
    let server = DeliveryServer()
    let clock = TestClock()
    let selection: TestSelection
    private(set) var store: Store

    init(_ test: XCTestCase, locales: [String] = ["en"]) throws {
        root = try StoreFixtures.root(for: test)
        selection = TestSelection(locales)
        store = try StoreFixtures.store(root)
    }

    func cycle() throws -> UpdateCycle {
        let clock = self.clock, selection = self.selection
        let client = DeliveryClient(endpoint: try DeliveryFixtures.endpoint(), identity: DeliveryFixtures.identity, transport: server)
        return UpdateCycle(CycleEnvironment(client: client, store: store, now: { clock.now }, random: { 0 },
                                            selectLocales: { selection.select($0) }, uptime: { clock.uptime }))
    }

    /// A new process: a fresh Store over the same root, so state.json is read back from disk.
    func relaunch() throws {
        store = try StoreFixtures.store(root)
    }

    var state: StoreState {
        get async { await store.state }
    }

    /// Runs a cycle, then activates what it built, as chunk 5 will.
    @discardableResult
    func runAndActivate() async throws -> CycleReport {
        let report = try await cycle().run()
        if case .installed(let install) = report.outcome { try await store.activate(install) }
        return report
    }

    func file(_ install: InstallRecord?, _ slot: Slot) throws -> Data? {
        guard let install, let url = store.fileURL(of: install, slot: slot) else { return nil }
        return try Data(contentsOf: url)
    }
}

enum CycleFixtures {
    static let enStrings = Slot(bundleId: "ns7", locale: "en", fileType: "strings")
    static let arStrings = Slot(bundleId: "ns7", locale: "ar", fileType: "strings")

    static func problem(_ status: Int, code: String, pollAfter: Int? = nil, retryAfter: Int? = nil) -> FakeTransport.Answer {
        var body: [String: Any] = ["status": status, "code": code, "title": code]
        if let pollAfter { body["pollAfter"] = pollAfter }
        var headers = ["Content-Type": "application/problem+json"]
        if let retryAfter { headers["Retry-After"] = String(retryAfter) }
        return .json(status, body, headers: headers)
    }
}
