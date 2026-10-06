import Foundation
import XCTest
@testable import Tarjim

/// The runtime's wiring that only shows over a whole session: timers stopped, time away counted, the key kept private.
final class RuntimeWiringTests: XCTestCase {
    private var storeIdentifier: String {
        StoreIdentifier.make(host: DeliveryFixtures.host, projectId: DeliveryFixtures.projectId, apiKey: DeliveryFixtures.apiKey)
    }

    /// Resigning really stops the timers: once released, a stopped schedule makes no further request.
    func testResigningStopsTheTimers() async throws {
        let harness = try RuntimeHarness(self)
        harness.server.publish(try Release.one())
        harness.instantSleeps.value = 2
        let runtime = try harness.make()
        await runtime.start(foreground: true)
        await runtime.becameActive()
        await EngineFixtures.settle()
        await runtime.resignedActive()
        let requests = harness.server.metaRequests.count
        harness.instantSleeps.value = 1_000
        harness.releaseBlockedSleeps.value = true
        harness.clock.advance(86_400)
        await EngineFixtures.settle()
        XCTAssertEqual(harness.server.metaRequests.count, requests)
    }

    /// Coming back after an hour away shows the update that was downloaded before leaving.
    func testTimeAwayIsCounted() async throws {
        let harness = try RuntimeHarness(self)
        harness.server.publish(try Release.one())
        harness.instantSleeps.value = 0
        let runtime = try harness.make()
        await runtime.start(foreground: true)
        await runtime.checkNow()
        harness.server.publish(try EngineFixtures.release(title: "Tarjim 2", releaseId: 43))
        harness.clock.advance(1800)
        await runtime.checkNow()
        XCTAssertEqual(runtime.string("app.title", bundle: nil), "Tarjim")
        await runtime.becameActive()
        await runtime.resignedActive()
        harness.clock.advance(Engine.longBackgroundSeconds)
        await runtime.becameActive()
        await EngineFixtures.settle(until: { runtime.string("app.title", bundle: nil) == "Tarjim 2" })
        XCTAssertEqual(runtime.string("app.title", bundle: nil), "Tarjim 2")
        await runtime.resignedActive()
    }

    /// A resolved "file still unavailable" condition is news again in a later process when it returns.
    func testAResolvedOwedFileIsReportedAgainInALaterProcess() async throws {
        let root = try StoreFixtures.root(for: self)
        let fileHash = String(repeating: "b", count: 64)
        let owed = CycleReport(outcome: .unchanged, nextCheckIn: 1800, signals: [.metaAnswered, .owed(hashes: [fileHash])])
        let first = TestValue<[TarjimReport]>([])
        let earlier = Reporter(store: try StoreFixtures.store(root), handler: { first.value.append($0) })
        for _ in 0..<3 { await earlier.cycleFinished(owed) }
        XCTAssertEqual(first.value.count, 1)
        let second = TestValue<[TarjimReport]>([])
        let later = Reporter(store: try StoreFixtures.store(root), handler: { second.value.append($0) })
        await later.cycleFinished(CycleReport(outcome: .unchanged, nextCheckIn: 1800, signals: [.metaAnswered, .owed(hashes: [])]))
        for _ in 0..<3 { await later.cycleFinished(owed) }
        XCTAssertEqual(second.value.count, 1)
    }

    /// The key never shows in a description, a debug description or a dump of what the app holds.
    func testTheKeyNeverShowsInDescriptions() throws {
        let harness = try RuntimeHarness(self)
        let configuration = harness.configuration()
        let runtime = try harness.make(configuration)
        var dumped = ""
        dump(runtime, to: &dumped)
        var dumpedConfiguration = ""
        dump(configuration, to: &dumpedConfiguration)
        for text in [String(describing: configuration), String(reflecting: configuration), dumped, dumpedConfiguration] {
            XCTAssertFalse(text.contains(DeliveryFixtures.apiKey), text)
        }
    }

    /// A second `start` on the same runtime changes nothing: the launch is counted once.
    func testASecondStartIsIgnored() async throws {
        let harness = try RuntimeHarness(self)
        harness.server.publish(try Release.one())
        let first = try harness.make()
        await first.start(foreground: true)
        await first.checkNow()
        let next = try harness.make()
        await next.start(foreground: true)
        await next.start(foreground: true)
        let state = await (try StoreFixtures.store(harness.root, identifier: storeIdentifier)).state
        XCTAssertEqual(state.launchCrashCount, 1)
    }

    /// `locale` is the locale downloaded text is served in, which can differ from the app's language.
    func testLocaleIsTheServedLocale() async throws {
        let harness = try RuntimeHarness(self)
        harness.appLanguage.value = "fr"
        harness.server.publish(try Release.one())
        let runtime = try harness.make()
        XCTAssertEqual(runtime.locale.identifier, "fr", "before anything is served")
        await runtime.start(foreground: true)
        await runtime.checkNow()
        XCTAssertEqual(runtime.locale.identifier, "en", "the fallback language is what is served")
    }

    /// Notifications arriving as resign-then-become (Control Center pulled down and back) leave the app active.
    func testQuickResignThenBecomeLeavesTheScheduleRunning() async throws {
        let harness = try RuntimeHarness(self)
        harness.server.publish(try Release.one())
        harness.instantSleeps.value = 2
        let runtime = try harness.make()
        await runtime.start(foreground: true)
        runtime.noteBecameActive()
        runtime.noteResignedActive()
        runtime.noteBecameActive()
        await EngineFixtures.settle(until: { harness.server.metaRequests.count >= 1 })
        XCTAssertGreaterThanOrEqual(harness.server.metaRequests.count, 1)
        let before = harness.server.metaRequests.count
        harness.clock.advance(86_400)
        harness.releaseBlockedSleeps.value = true
        harness.instantSleeps.value = harness.sleeps.value.count + 2
        await EngineFixtures.settle(until: { harness.server.metaRequests.count > before })
        XCTAssertGreaterThan(harness.server.metaRequests.count, before, "the schedule is still running")
        await runtime.resignedActive()
    }
}
