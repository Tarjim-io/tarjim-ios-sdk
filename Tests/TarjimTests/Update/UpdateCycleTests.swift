import Foundation
import XCTest
@testable import Tarjim

final class UpdateCycleTests: XCTestCase {
    private let en = CycleFixtures.enStrings

    // MARK: First install and reuse

    func testAFirstRunInstallsEveryWantedFileAsPending() async throws {
        let device = try Device(self, locales: ["en"])
        let release = try Release.one()
        device.server.publish(release)
        let report = try await device.cycle().run()
        guard case .installed(let install) = report.outcome else { return XCTFail("\(report)") }
        XCTAssertEqual(install.checksum, release.checksum)
        XCTAssertEqual(install.owedSlots, [])
        let state = await device.state
        XCTAssertEqual(state.pending, install, "built and recorded as pending; activation is not the cycle's job")
        XCTAssertNil(state.active)
        XCTAssertEqual(try device.file(install, en), release.objects["\(try release.hash(of: en)).strings"])
        let fetched = Set(device.server.objectRequests.map { $0.url!.lastPathComponent })
        XCTAssertTrue(fetched.allSatisfy { $0.hasSuffix(".strings") || $0.hasSuffix(".stringsdict") }, "no json, no other locale")
        XCTAssertEqual(fetched.count, device.server.objectRequests.count, "each object once")
        XCTAssertEqual(report.nextCheckIn, 1800, "random 0: exactly pollAfter")
    }

    /// Files are keyed by hash: a new release fetches only what changed.
    func testANewReleaseFetchesOnlyChangedFiles() async throws {
        let device = try Device(self, locales: ["en"])
        let one = try Release.one()
        device.server.publish(one)
        try await device.runAndActivate()
        let changed = Data("\"app.title\" = \"Tarjim 2\";".utf8)
        let two = try one.changing(releaseId: 43, slots: [en: changed])
        device.server.publish(two)
        device.server.resetRequests()
        device.clock.advance(1800)
        let report = try await device.cycle().run()
        guard case .installed(let install) = report.outcome else { return XCTFail("\(report)") }
        XCTAssertEqual(device.server.objectRequests.map { $0.url!.lastPathComponent }, ["\(Fixtures.sha256Hex(changed)).strings"])
        XCTAssertEqual(try device.file(install, en), changed)
        XCTAssertEqual(install.owedSlots, [])
    }

    /// A move to an OLDER release is a change like any other: compared by checksum, never by order.
    func testAMoveToAnOlderReleaseIsInstalled() async throws {
        let device = try Device(self, locales: ["en"])
        let one = try Release.one()
        let two = try one.changing(releaseId: 43, slots: [en: Data("\"a\" = \"2\";".utf8)])
        device.server.publish(two)
        try await device.runAndActivate()
        device.server.publish(one)
        device.clock.advance(1800)
        let report = try await device.cycle().run()
        guard case .installed(let install) = report.outcome else { return XCTFail("\(report)") }
        XCTAssertEqual(install.checksum, one.checksum)
    }

    // MARK: Cadence

    /// `pollAfter` is a minimum, across a relaunch too.
    func testMetaIsNotReadBeforePollAfterEvenAfterARelaunch() async throws {
        let device = try Device(self)
        device.server.publish(try Release.one())
        try await device.runAndActivate()
        device.server.resetRequests()
        device.clock.advance(1799)
        let report = try await device.cycle().run()
        XCTAssertEqual(report.outcome, .notDue)
        XCTAssertEqual(report.nextCheckIn, 1, accuracy: 0.001)
        XCTAssertEqual(device.server.requests.count, 0)
        device.clock.advance(1)
        let due = try await device.cycle().run()
        XCTAssertEqual(due.outcome, .unchanged)
        XCTAssertEqual(device.server.metaRequests.count, 1)
    }

    func testALastCheckInTheFutureIsDueNow() async throws {
        let device = try Device(self)
        device.server.publish(try Release.one())
        try await device.runAndActivate()
        device.clock.advance(-86_400)
        device.server.resetRequests()
        _ = try await device.cycle().run()
        XCTAssertEqual(device.server.metaRequests.count, 1)
    }

    /// Two callers at once share one cycle.
    func testConcurrentRunsShareOneCycle() async throws {
        let device = try Device(self)
        device.server.publish(try Release.one())
        let cycle = try device.cycle()
        async let a = cycle.run()
        async let b = cycle.run()
        let (first, second) = await (a, b)
        XCTAssertEqual(device.server.metaRequests.count, 1)
        XCTAssertEqual(first.outcome, second.outcome)
    }

    func testTheETagIsSentAndA304KeepsTheCadence() async throws {
        let device = try Device(self)
        device.server.publish(try Release.one())
        try await device.runAndActivate()
        device.server.answerMeta(FakeTransport.Answer(status: 304))
        device.clock.advance(1800)
        let report = try await device.cycle().run()
        XCTAssertEqual(report.outcome, .unchanged)
        XCTAssertEqual(report.nextCheckIn, 1800)
        let sent = try XCTUnwrap(device.server.metaRequests.last?.value(forHTTPHeaderField: "If-None-Match"))
        XCTAssertTrue(sent.hasPrefix("\"m42-"), "the ETag of the last 200: \(sent)")
    }

    // MARK: Failures keep what is held

    /// 5xx, 429 and network failures back off and keep every file.
    func testFailuresBackOffAndKeepWhatIsHeld() async throws {
        let device = try Device(self)
        device.server.publish(try Release.one())
        try await device.runAndActivate()
        let active = await device.state.active
        device.clock.advance(1800)
        device.server.answerMeta(FakeTransport.Answer(status: 502))
        var report = try await device.cycle().run()
        XCTAssertEqual(report.outcome, .failed)
        XCTAssertEqual(report.nextCheckIn, 60)
        device.clock.advance(60)
        device.server.goOffline()
        report = try await device.cycle().run()
        XCTAssertEqual(report.nextCheckIn, 120)
        device.clock.advance(119)
        let result1 = try await device.cycle().run()
        XCTAssertEqual(result1.outcome, .notDue, "the backoff survives a relaunch")
        device.clock.advance(1)
        device.server.goOffline(false)
        device.server.answerMeta(CycleFixtures.problem(429, code: "too-many-requests", retryAfter: 7200))
        report = try await device.cycle().run()
        XCTAssertEqual(report.nextCheckIn, 7200, "Retry-After beyond pollAfter")
        let state = await device.state
        XCTAssertEqual(state.active, active)
        XCTAssertNotNil(try device.file(active, en))
    }

    /// A revoked key that is restored later must recover without an app update.
    func testAConfigurationErrorKeepsPollingAtTheKnownCadence() async throws {
        let device = try Device(self)
        let release = try Release.one()
        device.server.publish(release)
        try await device.runAndActivate()
        device.clock.advance(1800)
        device.server.answerMeta(CycleFixtures.problem(401, code: "unauthorized"))
        let report = try await device.cycle().run()
        XCTAssertEqual(report.outcome, .configurationError(code: "unauthorized"))
        XCTAssertEqual(report.nextCheckIn, 1800)
        device.clock.advance(1800)
        device.server.publish(release)
        let result2 = try await device.cycle().run()
        XCTAssertEqual(result2.outcome, .unchanged)
    }

    /// A cold stage: nothing deleted, its own `pollAfter` (60 when absent), no other route tried.
    func testNothingReleasedYetIsSilentAndDeletesNothing() async throws {
        let device = try Device(self)
        device.server.answerMeta(CycleFixtures.problem(404, code: "delivery.stage_unreleased", pollAfter: 600))
        var report = try await device.cycle().run()
        XCTAssertEqual(report.outcome, .unreleased)
        XCTAssertEqual(report.nextCheckIn, 600)
        device.clock.advance(600)
        device.server.answerMeta(CycleFixtures.problem(404, code: "delivery.stage_unreleased"))
        report = try await device.cycle().run()
        XCTAssertEqual(report.nextCheckIn, 60)
        XCTAssertEqual(device.server.requests.count, device.server.metaRequests.count, "only meta, never another route")
    }

    func testAManifestFailingItsChecksumIsAFailureAndNothingIsStaged() async throws {
        let device = try Device(self)
        var release = try Release.one()
        device.server.publish(release)
        release = try release.changing(releaseId: 42)
        device.server.publish(Release(releaseId: 42, checksum: try Release.one().checksum, manifest: release.manifest,
                                      metaBody: try Release.one().metaBody, objects: [:]), meta: false)
        let report = try await device.cycle().run()
        XCTAssertEqual(report.outcome, .failed)
        XCTAssertEqual(report.nextCheckIn, 60, "a failed fetch backs off")
        XCTAssertEqual(device.server.manifestRequests.count, 1)
        XCTAssertEqual(device.server.objectRequests.count, 0)
        let state = await device.state
        XCTAssertNil(state.pending)
    }

    // MARK: Rejections

    func testAnUnknownSchemaVersionIsRejectedOnceAndNotFetchedAgain() async throws {
        let device = try Device(self)
        let one = try Release.one()
        device.server.publish(one)
        try await device.runAndActivate()
        let future = try one.changing(releaseId: 43, fields: ["schemaVersion": 2])
        device.server.publish(future)
        device.clock.advance(1800)
        let report = try await device.cycle().run()
        XCTAssertEqual(report.outcome, .rejected(checksum: future.checksum, .unknownSchema(2)))
        XCTAssertEqual(report.nextCheckIn, 1800, "polling continues")
        let state = await device.state
        XCTAssertTrue(state.rejectedChecksums.contains(future.checksum))
        XCTAssertNotNil(try device.file(state.active, en), "files kept")
        device.server.resetRequests()
        device.clock.advance(1800)
        let result3 = try await device.cycle().run()
        XCTAssertEqual(result3.outcome, .skipped)
        XCTAssertEqual(device.server.manifestRequests.count, 0)
    }

    func testAManifestWithNoStringsAnywhereIsRejected() async throws {
        let device = try Device(self)
        let one = try Release.one()
        var drop: [Slot: Data?] = [:]
        for bundle in ["ns7", "ns12", "ns15", "b3"] {
            for locale in ["en", "ar"] { drop[Slot(bundleId: bundle, locale: locale, fileType: "strings")] = .some(nil) }
        }
        let empty = try one.changing(releaseId: 43, slots: drop)
        device.server.publish(empty)
        let report = try await device.cycle().run()
        XCTAssertEqual(report.outcome, .rejected(checksum: empty.checksum, .noStrings))
        XCTAssertEqual(device.server.objectRequests.count, 0)
    }

    /// A checksum marked bad after launch crashes is never fetched again while `meta` names it.
    func testABadChecksumIsNotFetchedAgain() async throws {
        let device = try Device(self)
        let one = try Release.one()
        device.server.publish(one)
        var state = await device.state
        state.badChecksums = [one.checksum]
        try await device.store.save(state)
        let report = try await device.cycle().run()
        XCTAssertEqual(report.outcome, .skipped)
        XCTAssertEqual(device.server.manifestRequests.count, 0)
    }

    // MARK: Identity

    /// `meta` naming the active release while a newer one waits to be activated is a rollback.
    func testMetaNamingTheActiveReleaseDiscardsThePendingOne() async throws {
        let device = try Device(self)
        let one = try Release.one()
        device.server.publish(one)
        try await device.runAndActivate()
        let two = try one.changing(releaseId: 43, slots: [en: Data("\"a\" = \"2\";".utf8)])
        device.server.publish(two)
        device.clock.advance(1800)
        let pendingRun = try await device.cycle().run()
        guard case .installed = pendingRun.outcome else { return XCTFail("no pending") }
        device.server.publish(one)
        device.server.resetRequests()
        device.clock.advance(1800)
        let result4 = try await device.cycle().run()
        XCTAssertEqual(result4.outcome, .discardedPending)
        let state = await device.state
        XCTAssertNil(state.pending)
        XCTAssertEqual(state.active?.checksum, one.checksum)
        XCTAssertEqual(device.server.manifestRequests.count, 0)
    }

    /// Compared with the NEWEST install known: a pending one already holding this checksum means nothing to do.
    func testMetaNamingThePendingReleaseIsUnchanged() async throws {
        let device = try Device(self)
        device.server.publish(try Release.one())
        _ = try await device.cycle().run()
        device.clock.advance(1800)
        device.server.resetRequests()
        let result5 = try await device.cycle().run()
        XCTAssertEqual(result5.outcome, .unchanged)
        XCTAssertEqual(device.server.manifestRequests.count, 0)
    }

    // MARK: Unfetchable objects (C14, C15)

    /// A 403 on an object: `meta` is read again ONCE, without If-None-Match, and the object retried with it.
    func testAnExpiredSignatureIsRenewedOnceAndRetried() async throws {
        let device = try Device(self)
        let release = try Release.one()
        device.server.publish(release)
        device.server.answerObject(hash: try release.hash(of: en), fileType: "strings", try DeliveryFixtures.error("object-403-cdn-edge"))
        let report = try await device.cycle().run()
        guard case .installed(let install) = report.outcome else { return XCTFail("\(report)") }
        XCTAssertEqual(install.owedSlots, [])
        XCTAssertEqual(device.server.metaRequests.count, 2)
        XCTAssertNil(device.server.metaRequests[1].value(forHTTPHeaderField: "If-None-Match"))
    }

    /// Still failing after the one re-read: that slot is owed, the others install, and only one extra `meta` read.
    func testAStillUnfetchableObjectIsOwedAndBlocksOnlyItsSlot() async throws {
        let device = try Device(self)
        let release = try Release.one()
        device.server.publish(release)
        let hash = try release.hash(of: en)
        let gone = try DeliveryFixtures.error("object-403-cdn-edge")
        device.server.answerObject(hash: hash, fileType: "strings", gone, gone, gone)
        let report = try await device.cycle().run()
        guard case .installed(let install) = report.outcome else { return XCTFail("\(report)") }
        XCTAssertEqual(install.owedSlots, [en])
        XCTAssertNotNil(try device.file(install, CycleFixtures.enStrings.with(fileType: "stringsdict")))
        XCTAssertEqual(device.server.metaRequests.count, 2)
    }

    /// An owed slot that fails again creates no install and no event.
    func testAnOwedSlotFailingAgainChangesNothing() async throws {
        let device = try Device(self)
        let release = try Release.one()
        device.server.publish(release)
        let hash = try release.hash(of: en)
        let gone = try DeliveryFixtures.error("object-404-slice-not-found")
        device.server.answerObject(hash: hash, fileType: "strings", gone, gone, gone, gone)
        try await device.runAndActivate()
        device.clock.advance(1800)
        let result6 = try await device.cycle().run()
        XCTAssertEqual(result6.outcome, .unchanged)
        let state = await device.state
        XCTAssertNil(state.pending)
    }

    /// An owed slot is retried in the next due cycle with the fresh signature; success is a new install.
    func testAnOwedSlotIsRetriedInTheNextDueCycle() async throws {
        let device = try Device(self)
        let release = try Release.one()
        device.server.publish(release)
        let hash = try release.hash(of: en)
        let gone = try DeliveryFixtures.error("object-404-slice-not-found")
        device.server.answerObject(hash: hash, fileType: "strings", gone, gone)
        try await device.runAndActivate()
        device.clock.advance(1800)
        let report = try await device.cycle().run()
        guard case .installed(let install) = report.outcome else { return XCTFail("\(report)") }
        XCTAssertEqual(install.checksum, release.checksum)
        XCTAssertEqual(install.owedSlots, [])
    }

    /// A network failure mid-download keeps the verified files staged; the next cycle fetches only the rest.
    func testAnInterruptedDownloadResumesFromStaging() async throws {
        let device = try Device(self)
        let release = try Release.one()
        device.server.publish(release)
        device.server.answerObject(hash: try release.hash(of: en), fileType: "strings", FakeTransport.Answer(status: 500))
        let report = try await device.cycle().run()
        XCTAssertEqual(report.outcome, .failed)
        let fetchedBefore = Set(device.server.objectRequests.map { $0.url!.lastPathComponent })
        device.server.resetRequests()
        device.clock.advance(report.nextCheckIn)
        let pendingRun = try await device.cycle().run()
        guard case .installed = pendingRun.outcome else { return XCTFail("no install") }
        let fetchedAfter = device.server.objectRequests.map { $0.url!.lastPathComponent }
        XCTAssertTrue(fetchedAfter.contains("\(try release.hash(of: en)).strings"))
        XCTAssertTrue(Set(fetchedAfter).isDisjoint(with: fetchedBefore.subtracting(["\(try release.hash(of: en)).strings"])),
                      "verified files were not fetched twice")
    }
}

final class LanguageChangeTests: XCTestCase {
    /// A locale the held manifest lists is fetched now, with the signature held, without waiting for `meta`.
    func testANewlySelectedLocaleIsFetchedWithoutReadingMeta() async throws {
        let device = try Device(self, locales: ["en"])
        let release = try Release.one()
        device.server.publish(release)
        try await device.runAndActivate()
        device.server.resetRequests()
        device.selection.set(["ar"])
        let report = try await device.cycle().languageChanged()
        guard case .installed(let install) = report.outcome else { return XCTFail("\(report)") }
        XCTAssertEqual(install.checksum, release.checksum)
        XCTAssertNotNil(try device.file(install, CycleFixtures.arStrings))
        XCTAssertEqual(device.server.metaRequests.count, 0)
        XCTAssertEqual(device.server.manifestRequests.count, 0, "the held manifest is read from disk")
    }

    /// The held signature refused: `meta` is read once, outside the cadence, and the files fetched with it.
    func testARefusedSignatureReadsMetaOnce() async throws {
        let device = try Device(self, locales: ["en"])
        let release = try Release.one()
        device.server.publish(release)
        try await device.runAndActivate()
        device.server.resetRequests()
        device.server.answerObject(hash: try release.hash(of: CycleFixtures.arStrings), fileType: "strings",
                                   try DeliveryFixtures.error("object-403-cdn-edge"))
        device.selection.set(["ar"])
        let report = try await device.cycle().languageChanged()
        guard case .installed(let install) = report.outcome else { return XCTFail("\(report)") }
        XCTAssertEqual(install.owedSlots, [])
        XCTAssertEqual(device.server.metaRequests.count, 1)
    }

    func testNothingNewToFetchMakesNoRequest() async throws {
        let device = try Device(self, locales: ["en", "ar"])
        device.server.publish(try Release.one())
        try await device.runAndActivate()
        device.server.resetRequests()
        device.selection.set(["ar"])
        let result7 = try await device.cycle().languageChanged()
        XCTAssertEqual(result7.outcome, .unchanged)
        XCTAssertEqual(device.server.requests.count, 0)
    }
}

private extension Slot {
    func with(fileType: String) -> Slot { Slot(bundleId: bundleId, locale: locale, fileType: fileType) }
}
