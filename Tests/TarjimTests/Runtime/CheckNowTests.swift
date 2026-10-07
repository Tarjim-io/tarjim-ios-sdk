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
        harness.server.publish(try Release.one())
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

    // MARK: The minute and the backoff hold whatever the wall clock does

    func testSettingTheDateBackKeepsTheMinute() async throws {
        let harness = try RuntimeHarness(self)
        let runtime = try await installOne(harness)
        harness.clock.advance(120)
        _ = await runtime.checkOnRequest()
        let requests = harness.server.metaRequests.count
        harness.clock.jump(-3600)
        _ = await runtime.checkOnRequest()
        XCTAssertEqual(harness.server.metaRequests.count, requests)
    }

    func testSettingTheDateForwardKeepsTheMinute() async throws {
        let harness = try RuntimeHarness(self)
        let runtime = try await installOne(harness)
        harness.clock.advance(120)
        _ = await runtime.checkOnRequest()
        let requests = harness.server.metaRequests.count
        harness.clock.jump(3600)
        _ = await runtime.checkOnRequest()
        XCTAssertEqual(harness.server.metaRequests.count, requests)
    }

    func testSettingTheDateBackDuringARetryAfterReadsNothing() async throws {
        let harness = try RuntimeHarness(self)
        let runtime = try await installOne(harness)
        harness.clock.advance(120)
        harness.server.answerMeta(CycleFixtures.problem(429, code: "too-many-requests", retryAfter: 600))
        _ = await runtime.checkOnRequest()
        let requests = harness.server.metaRequests.count
        harness.clock.advance(61)
        harness.clock.jump(-3600)
        let during = await runtime.checkOnRequest()
        XCTAssertEqual(during, .notDue)
        XCTAssertEqual(harness.server.metaRequests.count, requests)
    }

    /// The backoff is kept in memory too: a store that cannot save must not let requests read through a Retry-After.
    func testAFailedSaveStillHoldsTheBackoff() async throws {
        let harness = try RuntimeHarness(self)
        let runtime = try await installOne(harness)
        harness.clock.advance(120)
        let stores = try FileManager.default.contentsOfDirectory(at: harness.root.appendingPathComponent("Tarjim/v1"),
                                                                 includingPropertiesForKeys: nil)
        for store in stores { try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: store.path) }
        addTeardownBlock {
            for store in stores { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: store.path) }
        }
        harness.server.answerMeta(CycleFixtures.problem(429, code: "too-many-requests", retryAfter: 600))
        let failed = await runtime.checkOnRequest()
        XCTAssertEqual(failed, .failed)
        let requests = harness.server.metaRequests.count
        harness.clock.advance(61)
        let during = await runtime.checkOnRequest()
        XCTAssertEqual(during, .notDue)
        XCTAssertEqual(harness.server.metaRequests.count, requests)
    }

    // MARK: Results inside and after the minute

    func testAFailureIsTheAnswerForTheRestOfTheMinute() async throws {
        let harness = try RuntimeHarness(self)
        let runtime = try await installOne(harness)
        harness.clock.advance(120)
        harness.server.goOffline()
        let failed = await runtime.checkOnRequest()
        XCTAssertEqual(failed, .failed)
        harness.server.goOffline(false)
        let requests = harness.server.metaRequests.count
        harness.clock.advance(30)
        let again = await runtime.checkOnRequest()
        XCTAssertEqual(again, .failed)
        XCTAssertEqual(harness.server.metaRequests.count, requests)
    }

    /// A call that made no request opens no minute: once the backoff ends, the next call reads.
    func testNotDueOpensNoMinute() async throws {
        let harness = try RuntimeHarness(self)
        let runtime = try await installOne(harness)
        harness.clock.advance(120)
        harness.server.answerMeta(CycleFixtures.problem(429, code: "too-many-requests", retryAfter: 90))
        _ = await runtime.checkOnRequest()
        harness.clock.advance(61)
        let waiting = await runtime.checkOnRequest()
        XCTAssertEqual(waiting, .notDue)
        harness.server.publish(try Release.one())
        harness.clock.advance(30)
        let requests = harness.server.metaRequests.count
        let after = await runtime.checkOnRequest()
        XCTAssertEqual(after, .noChange)
        XCTAssertEqual(harness.server.metaRequests.count, requests + 1)
    }

    func testAKeyProblemIsFailed() async throws {
        let harness = try RuntimeHarness(self)
        let runtime = try await installOne(harness)
        harness.clock.advance(120)
        harness.server.answerMeta(CycleFixtures.problem(401, code: "unauthorized"))
        let result = await runtime.checkOnRequest()
        XCTAssertEqual(result, .failed)
    }

    // MARK: Sharing a cycle with the schedule

    /// The cycle a request joins is handled and reported once: one event, and a missing file counted once per cycle.
    func testACycleSharedWithTheScheduleCountsOnce() async throws {
        let harness = try RuntimeHarness(self)
        let runtime = try await installOne(harness)
        let seen = TestValue<[TarjimUpdate]>([])
        let stream = runtime.updates()
        Task { for await update in stream { seen.value.append(update) } }
        harness.server.publish(try EngineFixtures.release(title: "Tarjim 2", releaseId: 43))
        harness.clock.advance(1800)
        let gate = Gate()
        harness.server.onObjectRequest = { gate.hold() }
        let scheduled = Task { await runtime.checkNow() }
        try await gate.waitUntilHeld()
        let requested = Task { await runtime.checkOnRequest() }
        try await Task.sleep(nanoseconds: 200_000_000)
        gate.open()
        _ = await scheduled.value
        let result = await requested.value
        XCTAssertEqual(result, .downloaded)
        await EngineFixtures.settle(until: { !seen.value.isEmpty })
        XCTAssertEqual(seen.value, [.downloaded])
        XCTAssertEqual(harness.server.metaRequests.count, 2, "the launch's read and one shared read")
    }

    func testASharedCycleReachesTheReporterOnce() async throws {
        let harness = try RuntimeHarness(self)
        let runtime = try await installOne(harness)
        let two = try EngineFixtures.release(title: "Tarjim 2", releaseId: 43)
        harness.server.publish(two)
        let gone = FakeTransport.Answer(status: 404)
        harness.server.answerObject(hash: try two.hash(of: EngineFixtures.titleSlot), fileType: "strings",
                                    gone, gone, gone, gone, gone, gone, gone, gone)
        harness.clock.advance(1800)
        let gate = Gate()
        harness.server.onObjectRequest = { gate.hold() }
        let scheduled = Task { await runtime.checkNow() }
        try await gate.waitUntilHeld()
        let requested = Task { await runtime.checkOnRequest() }
        try await Task.sleep(nanoseconds: 200_000_000)
        gate.open()
        _ = await scheduled.value
        _ = await requested.value
        harness.clock.advance(4000)
        await runtime.checkNow()
        XCTAssertEqual(harness.reports.value.map(\.kind), [], "two cycles without the file are not yet a condition")
    }

    // MARK: Only while the app is active

    func testInABackgroundLaunchItReadsNothing() async throws {
        let harness = try RuntimeHarness(self)
        harness.server.publish(try Release.one())
        let runtime = try harness.make()
        await runtime.start(foreground: false)
        let result = await runtime.checkOnRequest()
        XCTAssertEqual(result, .notDue)
        XCTAssertEqual(harness.server.requests.count, 0)
    }

    func testAfterTheAppResignsItReadsNothing() async throws {
        let harness = try RuntimeHarness(self)
        let runtime = try await installOne(harness)
        await runtime.becameActive()
        await runtime.resignedActive()
        harness.clock.advance(120)
        let requests = harness.server.metaRequests.count
        let result = await runtime.checkOnRequest()
        XCTAssertEqual(result, .notDue)
        XCTAssertEqual(harness.server.metaRequests.count, requests)
    }

    // MARK: A backoff the schedule started holds requests too

    private func lockStores(_ harness: RuntimeHarness) throws {
        let stores = try FileManager.default.contentsOfDirectory(at: harness.root.appendingPathComponent("Tarjim/v1"),
                                                                 includingPropertiesForKeys: nil)
        for store in stores { try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: store.path) }
        addTeardownBlock {
            for store in stores { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: store.path) }
        }
    }

    /// Release one shown, then a scheduled check answered 429 with a Retry-After of 600 s.
    private func scheduledRetryAfter(_ harness: RuntimeHarness, lockingStores: Bool = false) async throws -> Runtime {
        let runtime = try await installOne(harness)
        harness.clock.advance(1800)
        if lockingStores { try lockStores(harness) }
        harness.server.answerMeta(CycleFixtures.problem(429, code: "too-many-requests", retryAfter: 600))
        let scheduled = await runtime.checkNow()
        XCTAssertEqual(scheduled.outcome, .failed)
        harness.server.publish(try Release.one())
        return runtime
    }

    func testAScheduledRetryAfterHoldsRequests() async throws {
        let harness = try RuntimeHarness(self)
        let runtime = try await scheduledRetryAfter(harness)
        let requests = harness.server.metaRequests.count
        harness.clock.advance(61)
        let during = await runtime.checkOnRequest()
        XCTAssertEqual(during, .notDue)
        XCTAssertEqual(harness.server.metaRequests.count, requests)
    }

    func testAScheduledRetryAfterHoldsRequestsWhenItCouldNotBeSaved() async throws {
        let harness = try RuntimeHarness(self)
        let runtime = try await scheduledRetryAfter(harness, lockingStores: true)
        let requests = harness.server.metaRequests.count
        harness.clock.advance(61)
        let during = await runtime.checkOnRequest()
        XCTAssertEqual(during, .notDue)
        XCTAssertEqual(harness.server.metaRequests.count, requests)
    }

    func testAScheduledRetryAfterHoldsRequestsWhenTheDateIsSetBack() async throws {
        let harness = try RuntimeHarness(self)
        let runtime = try await scheduledRetryAfter(harness)
        let requests = harness.server.metaRequests.count
        harness.clock.jump(-5)
        let during = await runtime.checkOnRequest()
        XCTAssertEqual(during, .notDue)
        XCTAssertEqual(harness.server.metaRequests.count, requests)
    }

    func testAScheduledRetryAfterHoldsRequestsWhenTheDateIsSetForward() async throws {
        let harness = try RuntimeHarness(self)
        let runtime = try await scheduledRetryAfter(harness)
        let requests = harness.server.metaRequests.count
        harness.clock.advance(5)
        harness.clock.jump(700)
        let during = await runtime.checkOnRequest()
        XCTAssertEqual(during, .notDue)
        XCTAssertEqual(harness.server.metaRequests.count, requests)
    }

    func testAScheduledBackoffHoldsARequestRacingTheNextScheduledCheck() async throws {
        let harness = try RuntimeHarness(self)
        let runtime = try await installOne(harness)
        harness.clock.advance(1800)
        harness.server.answerMeta(CycleFixtures.problem(503, code: "unavailable"))
        _ = await runtime.checkNow()
        let requests = harness.server.metaRequests.count
        harness.clock.advance(10)
        async let scheduled = runtime.checkNow()
        async let requested = runtime.checkOnRequest()
        let (_, result) = await (scheduled, requested)
        XCTAssertEqual(result, .notDue)
        XCTAssertEqual(harness.server.metaRequests.count, requests)
    }

    // MARK: Other answers

    func testAReleaseTheDeviceCannotUseIsFailed() async throws {
        let harness = try RuntimeHarness(self)
        let runtime = try await installOne(harness)
        harness.server.publish(try Release.one().changing(releaseId: 43, fields: ["schemaVersion": 2]))
        harness.clock.advance(120)
        let result = await runtime.checkOnRequest()
        XCTAssertEqual(result, .failed)
    }

    func testBackInTheForegroundAfterABackgroundLaunchItReads() async throws {
        let harness = try RuntimeHarness(self)
        harness.server.publish(try Release.one())
        let runtime = try harness.make()
        await runtime.start(foreground: false)
        await runtime.becameActive()
        let result = await runtime.checkOnRequest()
        XCTAssertEqual(result, .downloaded)
    }

    /// A request that joins the schedule's first download answers once that download is shown, as it says.
    func testAJoinedFirstDownloadIsShownWhenTheAnswerArrives() async throws {
        let harness = try RuntimeHarness(self)
        harness.server.publish(try Release.one())
        let runtime = try harness.make()
        await runtime.start(foreground: true)
        let gate = Gate()
        harness.server.onObjectRequest = { gate.hold() }
        let scheduled = Task { await runtime.checkNow() }
        try await gate.waitUntilHeld()
        let requested = Task { () -> (TarjimCheckResult, String) in
            let result = await runtime.checkOnRequest()
            return (result, runtime.string("app.title", bundle: nil))
        }
        try await Task.sleep(nanoseconds: 100_000_000)
        gate.open()
        let (result, title) = await requested.value
        _ = await scheduled.value
        XCTAssertEqual(result, .downloaded)
        XCTAssertEqual(title, "Tarjim")
    }

    // MARK: Across a relaunch, and the other answers

    func testARelaunchDuringAScheduledRetryAfterStillHoldsRequests() async throws {
        for setBack in [false, true] {
            let harness = try RuntimeHarness(self)
            _ = try await scheduledRetryAfter(harness)
            let next = try harness.make()
            await next.start(foreground: true)
            let requests = harness.server.metaRequests.count
            if setBack { harness.clock.jump(-5) } else { harness.clock.advance(61) }
            let during = await next.checkOnRequest()
            XCTAssertEqual(during, .notDue, "date set back: \(setBack)")
            XCTAssertEqual(harness.server.metaRequests.count, requests, "date set back: \(setBack)")
        }
    }

    /// The schedule joining a request's cycle: one event, and the missing file counted once for the cycle.
    func testTheScheduleJoiningARequestCountsOnce() async throws {
        let harness = try RuntimeHarness(self)
        let runtime = try await installOne(harness)
        let seen = TestValue<[TarjimUpdate]>([])
        let stream = runtime.updates()
        Task { for await update in stream { seen.value.append(update) } }
        let two = try EngineFixtures.release(title: "Tarjim 2", releaseId: 43)
        harness.server.publish(two)
        let gone = FakeTransport.Answer(status: 404)
        harness.server.answerObject(hash: try two.hash(of: EngineFixtures.titleSlot), fileType: "strings",
                                    gone, gone, gone, gone, gone, gone, gone, gone)
        harness.clock.advance(1800)
        let gate = Gate()
        harness.server.onObjectRequest = { gate.hold() }
        let requested = Task { await runtime.checkOnRequest() }
        try await gate.waitUntilHeld()
        let scheduled = Task { await runtime.checkNow() }
        try await Task.sleep(nanoseconds: 200_000_000)
        gate.open()
        _ = await requested.value
        _ = await scheduled.value
        harness.clock.advance(4000)
        await runtime.checkNow()
        await EngineFixtures.settle(until: { !seen.value.isEmpty })
        XCTAssertEqual(seen.value.filter { $0 == .downloaded }.count, 1)
        XCTAssertEqual(harness.reports.value.map(\.kind), [])
    }

    /// Below the runtime's own guard: an engine launched in the background never shows a requested download.
    func testARequestInABackgroundLaunchShowsNothing() async throws {
        let process = try AppProcess(self)
        process.server.publish(try Release.one())
        await process.engine.launch(foreground: false)
        _ = await process.engine.checkOnRequest()
        let state = await process.state
        XCTAssertNil(state.active)
    }

    func testARequestedCheckReachesTheReportHandler() async throws {
        let harness = try RuntimeHarness(self)
        let runtime = try await installOne(harness)
        harness.server.publish(try Release.one().changing(releaseId: 43, fields: ["schemaVersion": 2]))
        harness.clock.advance(120)
        _ = await runtime.checkOnRequest()
        await EngineFixtures.settle(until: { !harness.reports.value.isEmpty })
        XCTAssertFalse(harness.reports.value.isEmpty)
    }

    func testNothingReleasedYetIsNoChange() async throws {
        let harness = try RuntimeHarness(self)
        let runtime = try await installOne(harness)
        harness.server.answerMeta(CycleFixtures.problem(404, code: "delivery.stage_unreleased", pollAfter: 900))
        harness.clock.advance(120)
        let result = await runtime.checkOnRequest()
        XCTAssertEqual(result, .noChange)
    }
}
