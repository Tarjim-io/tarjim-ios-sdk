import Foundation
import XCTest
@testable import Tarjim

/// `launch` is what `Tarjim.start` runs on the main thread: when it returns, the first lookup serves this launch's text.
final class RuntimeLaunchTests: XCTestCase {
    /// As the main thread would: a plain thread, not one of the pool the launch itself runs on.
    private func onAThread<T: Sendable>(_ body: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            Thread { continuation.resume(returning: body()) }.start()
        }
    }

    private func installOne(_ harness: RuntimeHarness) async throws {
        harness.server.publish(try Release.one())
        let first = try harness.make()
        await first.start(foreground: true)
        await first.checkNow()
        XCTAssertEqual(first.string("app.title", bundle: nil), "Tarjim")
    }

    func testTheActiveReleaseIsServedWhenLaunchReturns() async throws {
        let harness = try RuntimeHarness(self)
        try await installOne(harness)
        let runtime = try harness.make()
        let (ready, title) = await onAThread {
            (runtime.launch(foreground: true, waitingUpTo: 5), runtime.string("app.title", bundle: nil))
        }
        XCTAssertTrue(ready)
        XCTAssertEqual(title, "Tarjim")
    }

    func testAPendingReleaseIsShownByTheColdStartBeforeLaunchReturns() async throws {
        let harness = try RuntimeHarness(self)
        try await installOne(harness)
        // In the background, so this process isn't counted as a second cut-short launch, which would revert.
        let second = try harness.make()
        await second.start(foreground: false)
        harness.server.publish(try EngineFixtures.release(title: "Tarjim 2", releaseId: 43))
        harness.clock.advance(3600)
        await second.checkNow()
        XCTAssertEqual(second.string("app.title", bundle: nil), "Tarjim", "pending until the next cold start")
        let third = try harness.make()
        let (ready, title) = await onAThread {
            (third.launch(foreground: true, waitingUpTo: 5), third.string("app.title", bundle: nil))
        }
        XCTAssertTrue(ready)
        XCTAssertEqual(title, "Tarjim 2")
    }

    func testTheMainBundleIsRoutedWhenLaunchReturns() async throws {
        let harness = try RuntimeHarness(self)
        let runtime = try harness.make()
        let bundle = harness.appBundle
        let routed = await onAThread {
            _ = runtime.launch(foreground: true, waitingUpTo: 0)
            return MainBundleProxy.isInstalled(on: bundle)
        }
        XCTAssertTrue(routed)
    }

    /// The stored choice names a language the active release lacks, so the launch fetches it; that fetch must not
    /// hold `launch`.
    func testAServerThatNeverAnswersDoesNotHoldLaunch() async throws {
        let harness = try RuntimeHarness(self)
        try await installOne(harness)
        let silent = SilentTransport()
        let runtime = try harness.make(transport: silent)
        await runtime.setLanguage("ar")
        let ready = await onAThread { runtime.launch(foreground: true, waitingUpTo: 5) }
        XCTAssertTrue(ready)
        for _ in 0..<500 where silent.requests.value == 0 { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertGreaterThan(silent.requests.value, 0, "the launch went on to the network")
    }

    /// A launch the system makes in the background (a push, a fetch) may look strings up too.
    func testABackgroundLaunchServesTheActiveReleaseWhenItReturns() async throws {
        let harness = try RuntimeHarness(self)
        try await installOne(harness)
        let runtime = try harness.make()
        let (ready, title) = await onAThread {
            (runtime.launch(foreground: false, waitingUpTo: 5), runtime.string("app.title", bundle: nil))
        }
        XCTAssertTrue(ready)
        XCTAssertEqual(title, "Tarjim")
    }

    func testAnUnreadableStoreStillLetsLaunchReturnReady() async throws {
        let harness = try RuntimeHarness(self)
        try await installOne(harness)
        let files = FileManager.default.enumerator(at: harness.root, includingPropertiesForKeys: nil)?.allObjects as? [URL] ?? []
        for url in files where url.lastPathComponent == "state.json" {
            try FileManager.default.removeItem(at: url)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        let runtime = try harness.make()
        let (ready, title) = await onAThread {
            (runtime.launch(foreground: true, waitingUpTo: 5), runtime.string("app.only", bundle: nil))
        }
        XCTAssertTrue(ready)
        XCTAssertEqual(title, "From the app")
    }

    func testPastTheBoundTheLaunchStillCompletes() async throws {
        let harness = try RuntimeHarness(self)
        try await installOne(harness)
        let runtime = try harness.make()
        _ = await onAThread { runtime.launch(foreground: true, waitingUpTo: 0) }
        for _ in 0..<500 where runtime.string("app.title", bundle: nil) != "Tarjim" {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(runtime.string("app.title", bundle: nil), "Tarjim")
    }

    func testASecondLaunchReturnsReadyAndStartsNothing() async throws {
        let harness = try RuntimeHarness(self)
        try await installOne(harness)
        let runtime = try harness.make()
        let first = await onAThread { runtime.launch(foreground: true, waitingUpTo: 5) }
        XCTAssertTrue(first)
        harness.server.resetRequests()
        await EngineFixtures.settle()
        let requestsBefore = harness.server.requests.count
        let again = await onAThread { runtime.launch(foreground: true, waitingUpTo: 0) }
        XCTAssertTrue(again)
        await EngineFixtures.settle()
        XCTAssertEqual(harness.server.requests.count, requestsBefore)
    }
}

/// A server that accepts every request and never answers it.
private struct SilentTransport: Transport {
    let requests = TestValue<Int>(0)

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.value += 1
        while !Task.isCancelled { try await Task.sleep(nanoseconds: 50_000_000) }
        throw CancellationError()
    }
}

final class ReadyLatchTests: XCTestCase {
    /// On a plain thread, as the latch requires; the expectation fails the test instead of letting a wait hang the run.
    private func onAThread<T: Sendable>(_ body: @escaping @Sendable () -> T) async -> T? {
        let result = TestValue<T?>(nil)
        let done = expectation(description: "returned")
        Thread {
            result.value = body()
            done.fulfill()
        }.start()
        await fulfillment(of: [done], timeout: 5)
        return result.value
    }

    private static func seconds(since start: UInt64) -> Double {
        Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000_000
    }

    func testAClosedLatchWaitsOutItsBoundAndSaysSo() async {
        let latch = ReadyLatch()
        let outcome = await onAThread { () -> [Double] in
            let start = DispatchTime.now().uptimeNanoseconds
            let opened = latch.wait(upTo: 0.2)
            return [opened ? 1 : 0, Self.seconds(since: start)]
        }
        XCTAssertEqual(outcome?[0], 0)
        XCTAssertGreaterThanOrEqual(outcome?[1] ?? 0, 0.19)
        XCTAssertLessThan(outcome?[1] ?? .infinity, 1.2)
        XCTAssertFalse(latch.isOpen)
    }

    func testAnOpenLatchReturnsAtOnce() {
        let latch = ReadyLatch()
        latch.open()
        latch.open()
        XCTAssertTrue(latch.wait(upTo: 0))
        XCTAssertTrue(latch.isOpen)
    }

    func testOpeningReleasesAWaiter() async {
        let latch = ReadyLatch()
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) { latch.open() }
        let released = await onAThread { latch.wait(upTo: 10) }
        XCTAssertEqual(released, true)
    }

    func testAnUnboundedWaitStillReturnsWhenOpened() async {
        let latch = ReadyLatch()
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) { latch.open() }
        let released = await onAThread { latch.wait(upTo: .infinity) }
        XCTAssertEqual(released, true)
    }
}
