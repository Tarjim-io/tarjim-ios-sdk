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
        let second = try harness.make()
        await second.start(foreground: true)
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

    /// Nothing stored, so the launch fetches the user's locales; that fetch must not hold `launch`.
    func testAServerThatNeverAnswersDoesNotHoldLaunch() async throws {
        let harness = try RuntimeHarness(self)
        let runtime = try harness.make(transport: SilentTransport())
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
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        while !Task.isCancelled { try await Task.sleep(nanoseconds: 50_000_000) }
        throw CancellationError()
    }
}
