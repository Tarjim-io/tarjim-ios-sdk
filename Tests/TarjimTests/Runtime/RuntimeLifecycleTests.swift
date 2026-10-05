import Foundation
import XCTest
@testable import Tarjim

/// The runtime across an app's life: active and inactive, short sessions, a handler added in a later version.
final class RuntimeLifecycleTests: XCTestCase {
    private let checksum = String(repeating: "a", count: 64)

    /// Ten seconds in the foreground prove an install, however long the next check is away; healthy short sessions
    /// never revert a release.
    func testShortHealthySessionsDoNotRevert() async throws {
        let harness = try RuntimeHarness(self)
        harness.server.publish(try Release.one())
        for _ in 0..<3 {
            harness.instantSleeps.value = harness.sleeps.value.count + 2
            let runtime = try harness.make()
            await runtime.start(foreground: true)
            await runtime.becameActive()
            await EngineFixtures.settle()
            await runtime.resignedActive()
            harness.clock.advance(3600)
        }
        XCTAssertEqual(harness.reports.value.map(\.kind), [])
        let identifier = StoreIdentifier.make(host: DeliveryFixtures.host, projectId: DeliveryFixtures.projectId, apiKey: DeliveryFixtures.apiKey)
        let state = await (try StoreFixtures.store(harness.root, identifier: identifier)).state
        XCTAssertNotNil(state.active, "the release was installed by the schedule and stayed")
        XCTAssertEqual(state.badChecksums, [])
    }

    /// Checks run only while the app is active: none for a background launch, none after resigning.
    func testChecksRunOnlyWhileActive() async throws {
        let harness = try RuntimeHarness(self)
        harness.server.publish(try Release.one())
        harness.instantSleeps.value = 2
        let runtime = try harness.make()
        await runtime.start(foreground: false)
        await EngineFixtures.settle()
        XCTAssertEqual(harness.server.metaRequests.count, 0)
        await runtime.becameActive()
        await EngineFixtures.settle()
        XCTAssertEqual(harness.server.metaRequests.count, 1)
        await runtime.resignedActive()
        let after = harness.server.metaRequests.count
        harness.instantSleeps.value = 1_000
        await EngineFixtures.settle()
        XCTAssertEqual(harness.server.metaRequests.count, after)
    }

    /// A lookup means the same before and after `start`: the default bundle and its table rule apply from the first frame.
    func testALookupMeansTheSameBeforeAndAfterStart() async throws {
        let harness = try RuntimeHarness(self)
        var configuration = harness.configuration()
        configuration.defaultBundle = .namespace("checkout")
        let runtime = try harness.make(configuration)
        let before = runtime.string("app.only", bundle: nil)
        await runtime.start(foreground: true)
        XCTAssertEqual(before, "From the checkout table")
        XCTAssertEqual(runtime.string("app.only", bundle: nil), before)
    }

    /// A handler added in a later app version still hears a release this SDK keeps out.
    func testAHandlerAddedLaterHearsAStandingRejection() async throws {
        let harness = try RuntimeHarness(self)
        harness.server.publish(try Release.one().changing(releaseId: 43, fields: ["schemaVersion": 2]))
        var silent = harness.configuration()
        silent.onReport = nil
        let first = try harness.make(silent)
        await first.start(foreground: true)
        await first.checkNow()
        let later = try harness.make()
        await later.start(foreground: true)
        for _ in 0..<3 {
            harness.clock.advance(3600)
            await later.checkNow()
        }
        XCTAssertEqual(harness.reports.value.map(\.kind), [.unknownSchemaVersion(2)])
    }

    /// A file failing its hash in a cycle that builds nothing is still one report, not one per cycle.
    func testAFileHashMismatchWithNoInstallIsReportedOnce() async throws {
        let harness = try RuntimeHarness(self)
        let release = try Release.one()
        harness.server.publish(release)
        let tampered = FakeTransport.Answer(status: 200, body: Data("tampered".utf8))
        let throttled = FakeTransport.Answer(status: 429)
        harness.server.answerObject(hash: try release.hash(of: Slot(bundleId: "b3", locale: "en", fileType: "strings")), fileType: "strings",
                                    tampered, tampered, tampered, tampered)
        harness.server.answerObject(hash: try release.hash(of: Slot(bundleId: "ns7", locale: "en", fileType: "strings")), fileType: "strings",
                                    throttled, throttled, throttled, throttled)
        let runtime = try harness.make()
        await runtime.start(foreground: true)
        for _ in 0..<3 {
            await runtime.checkNow()
            harness.clock.advance(86_400)
        }
        let kinds = harness.reports.value.map { "\($0.kind)" }
        XCTAssertEqual(kinds.count, Set(kinds).count, "each condition once: \(kinds)")
    }

    /// An install shown mid-session (a first download, a language switch, `activatePendingUpdate`) is proven by staying in
    /// the foreground in that same session.
    func testAMidSessionActivationIsProvenInThatSession() async throws {
        let harness = try RuntimeHarness(self)
        harness.server.answerMeta(FakeTransport.Answer(status: 503))
        harness.instantSleeps.value = 2
        let runtime = try harness.make()
        await runtime.start(foreground: true)
        await runtime.becameActive()
        await EngineFixtures.settle()
        harness.server.publish(try Release.one())
        harness.clock.advance(86_400)
        harness.instantSleeps.value = harness.sleeps.value.count + 1
        await runtime.checkNow()
        await EngineFixtures.settle()
        let identifier = StoreIdentifier.make(host: DeliveryFixtures.host, projectId: DeliveryFixtures.projectId, apiKey: DeliveryFixtures.apiKey)
        let state = await (try StoreFixtures.store(harness.root, identifier: identifier)).state
        XCTAssertNotNil(state.active)
        XCTAssertNil(state.probation, "the app stayed active long enough after the activation")
        await runtime.resignedActive()
    }

    /// Becoming active before `start` has finished still leads to a prompt first check, not one an hour later.
    func testBecomingActiveBeforeStartStillChecksPromptly() async throws {
        let harness = try RuntimeHarness(self)
        harness.server.publish(try Release.one())
        harness.instantSleeps.value = 3
        let runtime = try harness.make()
        await runtime.becameActive()
        await runtime.start(foreground: true)
        await EngineFixtures.settle()
        XCTAssertEqual(harness.server.metaRequests.count, 1)
        XCTAssertFalse(harness.sleeps.value.contains(3600), "\(harness.sleeps.value)")
        await runtime.resignedActive()
    }
}

final class ReporterEdgeTests: XCTestCase {
    private let checksum = String(repeating: "a", count: 64)

    private func reporter() throws -> (Reporter, TestValue<[TarjimReport]>) {
        let store = try StoreFixtures.store(try StoreFixtures.root(for: self))
        let seen = TestValue<[TarjimReport]>([])
        return (Reporter(store: store, handler: { seen.value.append($0) }), seen)
    }

    /// A cycle that could not reach the server says nothing about the manifest; it does not re-arm the report.
    func testAnOfflineCycleDoesNotReArmTheManifestMismatch() async throws {
        let (reporter, seen) = try reporter()
        let mismatch = CycleReport(outcome: .failed, nextCheckIn: 60, signals: [.metaAnswered, .manifestChecksumMismatch(metaChecksum: checksum)])
        await reporter.cycleFinished(mismatch)
        await reporter.cycleFinished(mismatch)
        await reporter.cycleFinished(CycleReport(outcome: .failed, nextCheckIn: 60))
        await reporter.cycleFinished(mismatch)
        await reporter.cycleFinished(mismatch)
        XCTAssertEqual(seen.value.count, 1)
    }

    /// Once resolved — a cycle that reached the server and got a good manifest — the same mismatch is news again.
    func testAResolvedMismatchIsReportedAgainIfItReturns() async throws {
        let (reporter, seen) = try reporter()
        let mismatch = CycleReport(outcome: .failed, nextCheckIn: 60, signals: [.metaAnswered, .manifestChecksumMismatch(metaChecksum: checksum)])
        await reporter.cycleFinished(mismatch)
        await reporter.cycleFinished(mismatch)
        await reporter.cycleFinished(CycleReport(outcome: .unchanged, nextCheckIn: 1800, signals: [.metaAnswered]))
        await reporter.cycleFinished(mismatch)
        await reporter.cycleFinished(mismatch)
        XCTAssertEqual(seen.value.count, 2)
    }

    func testTwoReportsOfOneConditionAtOnceReachTheHandlerOnce() async throws {
        let (reporter, seen) = try reporter()
        let checksum = self.checksum
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await reporter.reverted(checksum: checksum) }
            group.addTask { await reporter.reverted(checksum: checksum) }
        }
        XCTAssertEqual(seen.value.count, 1)
    }

    /// Without a handler, a condition resolved and then seen again is logged again.
    func testAResolvedConditionIsLoggedAgainWhenItReturns() async throws {
        let store = try StoreFixtures.store(try StoreFixtures.root(for: self))
        let reporter = Reporter(store: store, handler: nil)
        let lines = TestValue<[String]>([])
        Log.setSink { lines.value.append($0) }
        addTeardownBlock { Log.setSink(nil) }
        await reporter.cycleFinished(CycleReport(outcome: .configurationError(code: "unauthorized"), nextCheckIn: 1800))
        await reporter.cycleFinished(CycleReport(outcome: .unchanged, nextCheckIn: 1800, signals: [.metaAnswered]))
        await reporter.cycleFinished(CycleReport(outcome: .configurationError(code: "unauthorized"), nextCheckIn: 1800))
        XCTAssertEqual(lines.value.filter { $0.contains("unauthorized") }.count, 2)
    }

    /// An app can build a report itself, for its own tests of the handler.
    func testAReportCanBeBuiltByTheApp() {
        let report = TarjimReport(kind: .configuration(code: "unauthorized"), message: "m")
        XCTAssertEqual(report.kind, .configuration(code: "unauthorized"))
    }
}
