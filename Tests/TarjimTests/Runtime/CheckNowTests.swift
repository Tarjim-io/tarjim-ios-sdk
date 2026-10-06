import Foundation
import XCTest
@testable import Tarjim

/// `checkNow()`: one `meta` read on the app's request, at most once a minute, never past a backoff, and never showing
/// what it downloads except where a launch would.
final class CheckNowTests: XCTestCase {
    /// Release one installed and shown by a scheduled check at the start of the clock.
    private func installOne(_ harness: RuntimeHarness) async throws -> Runtime {
        harness.server.publish(try Release.one())
        let runtime = try harness.make()
        await runtime.start(foreground: true)
        await runtime.checkNow()
        XCTAssertEqual(runtime.string("app.title", bundle: nil), "Tarjim")
        return runtime
    }

    func testItReadsMetaBeforeTheScheduleWouldAndDoesNotShowWhatItGets() async throws {
        let harness = try RuntimeHarness(self)
        let runtime = try await installOne(harness)
        harness.server.publish(try EngineFixtures.release(title: "Tarjim 2", releaseId: 43))
        harness.clock.advance(120)
        let requests = harness.server.metaRequests.count
        let result = await runtime.checkOnRequest()
        XCTAssertEqual(result, .downloaded)
        XCTAssertEqual(harness.server.metaRequests.count, requests + 1)
        XCTAssertEqual(runtime.string("app.title", bundle: nil), "Tarjim", "shown later, as any download")
        let activated = await runtime.activatePendingUpdate()
        XCTAssertTrue(activated)
        XCTAssertEqual(runtime.string("app.title", bundle: nil), "Tarjim 2")
    }

    func testWithinAMinuteItRepeatsTheLastAnswerWithoutARequest() async throws {
        let harness = try RuntimeHarness(self)
        let runtime = try await installOne(harness)
        harness.server.publish(try EngineFixtures.release(title: "Tarjim 2", releaseId: 43))
        harness.clock.advance(120)
        let first = await runtime.checkOnRequest()
        XCTAssertEqual(first, .downloaded)
        let requests = harness.server.metaRequests.count
        harness.clock.advance(59)
        let again = await runtime.checkOnRequest()
        XCTAssertEqual(again, .downloaded)
        XCTAssertEqual(harness.server.metaRequests.count, requests)
        harness.clock.advance(1)
        let later = await runtime.checkOnRequest()
        XCTAssertEqual(later, .noChange)
        XCTAssertEqual(harness.server.metaRequests.count, requests + 1)
    }

    func testCallsTogetherShareOneRequest() async throws {
        let harness = try RuntimeHarness(self)
        let runtime = try await installOne(harness)
        harness.clock.advance(120)
        let requests = harness.server.metaRequests.count
        async let a = runtime.checkOnRequest()
        async let b = runtime.checkOnRequest()
        let results = await [a, b]
        XCTAssertEqual(results, [.noChange, .noChange])
        XCTAssertEqual(harness.server.metaRequests.count, requests + 1)
    }

    func testItNeverCutsABackoffShort() async throws {
        let harness = try RuntimeHarness(self)
        let runtime = try await installOne(harness)
        harness.clock.advance(120)
        harness.server.answerMeta(CycleFixtures.problem(429, code: "too-many-requests", retryAfter: 600))
        let failed = await runtime.checkOnRequest()
        XCTAssertEqual(failed, .failed)
        let requests = harness.server.metaRequests.count
        harness.clock.advance(61)
        let waiting = await runtime.checkOnRequest()
        XCTAssertEqual(waiting, .notDue, "Retry-After still runs")
        XCTAssertEqual(harness.server.metaRequests.count, requests)
        harness.clock.advance(600)
        let after = await runtime.checkOnRequest()
        XCTAssertEqual(after, .noChange)
        XCTAssertEqual(harness.server.metaRequests.count, requests + 1)
    }

    /// It counts as the last poll: the schedule's next read moves out by `pollAfter` from it.
    func testItMovesTheNextScheduledCheckOut() async throws {
        let harness = try RuntimeHarness(self)
        let runtime = try await installOne(harness)
        harness.clock.advance(1700)
        _ = await runtime.checkOnRequest()
        let requests = harness.server.metaRequests.count
        harness.clock.advance(200)
        let scheduled = await runtime.checkNow()
        XCTAssertEqual(scheduled.outcome, .notDue, "1 900 s after the first check, 200 s after the requested one")
        XCTAssertEqual(harness.server.metaRequests.count, requests)
    }

    func testBeforeStartThereIsNothingToCheck() async throws {
        let harness = try RuntimeHarness(self)
        harness.server.publish(try Release.one())
        let runtime = try harness.make()
        let result = await runtime.checkOnRequest()
        XCTAssertEqual(result, .notDue)
        XCTAssertEqual(harness.server.requests.count, 0)
    }

    /// With nothing held, the first download is shown at once, as it is for a scheduled check.
    func testTheFirstDownloadIsShownAsTheScheduleWouldShowIt() async throws {
        let harness = try RuntimeHarness(self)
        harness.server.publish(try Release.one())
        let runtime = try harness.make()
        await runtime.start(foreground: true)
        let result = await runtime.checkOnRequest()
        XCTAssertEqual(result, .downloaded)
        XCTAssertEqual(runtime.string("app.title", bundle: nil), "Tarjim")
    }

    func testAServerFailureIsFailed() async throws {
        let harness = try RuntimeHarness(self)
        let runtime = try await installOne(harness)
        harness.clock.advance(120)
        harness.server.goOffline()
        let result = await runtime.checkOnRequest()
        XCTAssertEqual(result, .failed)
    }
}
