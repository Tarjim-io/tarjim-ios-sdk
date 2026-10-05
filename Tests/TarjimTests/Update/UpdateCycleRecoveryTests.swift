import Foundation
import XCTest
@testable import Tarjim

/// The cycle's answers when things went wrong before: a failed language change, damaged files, a stage that moved
/// mid-cycle, a full disk.
final class UpdateCycleRecoveryTests: XCTestCase {
    private let en = CycleFixtures.enStrings
    private let ar = CycleFixtures.arStrings

    /// A locale selected while offline (or while the app was not running) is fetched by the next due cycle, even
    /// though `meta` is unchanged.
    func testALocaleStepAMissedIsFetchedByTheNextDueCycle() async throws {
        let device = try Device(self, locales: ["en"])
        let release = try Release.one()
        device.server.publish(release)
        try await device.runAndActivate()
        device.selection.set(["en", "ar"])
        device.server.goOffline()
        _ = try await device.cycle().languageChanged()
        device.server.goOffline(false)
        device.clock.advance(1800)
        let report = try await device.cycle().run()
        guard case .installed(let install) = report.outcome else { return XCTFail("\(report)") }
        XCTAssertNotNil(try device.file(install, ar))
        XCTAssertNotNil(try device.file(install, en))
    }

    /// A staged file cut short is fetched again, and the cycle settles instead of rebuilding the same release forever.
    func testADamagedStagedFileIsFetchedAgainAndTheCycleSettles() async throws {
        let device = try Device(self)
        let release = try Release.one()
        device.server.publish(release)
        let hash = try release.hash(of: en)
        let staging = device.store.directory.appendingPathComponent("staging/\(release.checksum)", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        try Data("garbage".utf8).write(to: staging.appendingPathComponent("\(hash).strings"))
        var state = await device.state
        state.stagingChecksum = release.checksum
        try await device.store.save(state)

        let report = try await device.cycle().run()
        guard case .installed(let install) = report.outcome else { return XCTFail("\(report)") }
        XCTAssertEqual(install.owedSlots, [])
        XCTAssertEqual(try device.file(install, en), release.objects["\(hash).strings"])
        try await device.store.activate(install)
        device.clock.advance(1800)
        let result1 = try await device.cycle().run()
        XCTAssertEqual(result1.outcome, .unchanged)
    }

    /// The re-read after an expired signature can show the stage has moved on; the release it left is not recorded, and the next check is soon.
    func testAReReadNamingAnotherReleaseRecordsNothing() async throws {
        let device = try Device(self)
        let one = try Release.one()
        let two = try one.changing(releaseId: 43, slots: [en: Data("\"a\" = \"2\";".utf8)])
        device.server.publish(two, meta: false)
        device.server.publish(one)
        device.server.answerMeta(one.metaAnswer(), two.metaAnswer())
        device.server.answerObject(hash: try one.hash(of: en), fileType: "strings", try DeliveryFixtures.error("object-403-cdn-edge"))
        let report = try await device.cycle().run()
        XCTAssertEqual(report.nextCheckIn, 60, "soon, but never a loop with no delay")
        XCTAssertEqual(report.outcome, .unchanged, "not a failure the app hears about")
        let state = await device.state
        XCTAssertNil(state.pending)
        device.clock.advance(60)
        let next = try await device.cycle().run()
        guard case .installed(let install) = next.outcome else { return XCTFail("\(next)") }
        XCTAssertEqual(install.checksum, two.checksum)
    }

    /// An unchanged signature means the object is gone, not expired — no second request for it this cycle.
    func testAnUnchangedSignatureIsNotRetried() async throws {
        let device = try Device(self)
        let release = try Release.one()
        device.server.publish(release)
        let hash = try release.hash(of: en)
        device.server.answerObject(hash: hash, fileType: "strings", try DeliveryFixtures.error("object-403-cdn-edge"))
        let report = try await device.cycle().run()
        guard case .installed(let install) = report.outcome else { return XCTFail("\(report)") }
        XCTAssertEqual(install.owedSlots, [en])
        XCTAssertEqual(device.server.objectRequests.filter { $0.url!.lastPathComponent == "\(hash).strings" }.count, 1)
        XCTAssertEqual(device.server.metaRequests.count, 2)
    }

    /// A configuration-class answer is not a failure streak: backoff starts again from 60 s afterwards.
    func testAConfigurationErrorResetsTheBackoff() async throws {
        let device = try Device(self)
        device.server.publish(try Release.one())
        try await device.runAndActivate()
        for _ in 0..<3 {
            device.clock.advance(3600)
            device.server.answerMeta(FakeTransport.Answer(status: 502))
            _ = try await device.cycle().run()
        }
        device.clock.advance(3600)
        device.server.answerMeta(CycleFixtures.problem(401, code: "unauthorized"))
        _ = try await device.cycle().run()
        device.clock.advance(3600)
        device.server.answerMeta(FakeTransport.Answer(status: 502))
        let report = try await device.cycle().run()
        XCTAssertEqual(report.nextCheckIn, 60)
    }

    /// An unreleased stage's `pollAfter` is the cadence it asked for, so backoff is capped by it.
    func testAnUnreleasedPollAfterCapsTheBackoff() async throws {
        let device = try Device(self)
        device.server.answerMeta(CycleFixtures.problem(404, code: "delivery.stage_unreleased", pollAfter: 300))
        _ = try await device.cycle().run()
        var last: TimeInterval = 0
        for _ in 0..<6 {
            device.clock.advance(3600)
            device.server.answerMeta(FakeTransport.Answer(status: 503))
            last = try await device.cycle().run().nextCheckIn
        }
        XCTAssertEqual(last, 300)
    }

    /// A due `run()` arriving during a language change polls `meta` itself rather than taking the language change's answer.
    func testARunDuringALanguageChangeStillPolls() async throws {
        let device = try Device(self, locales: ["en"])
        device.server.publish(try Release.one())
        try await device.runAndActivate()
        device.clock.advance(1800)
        device.server.resetRequests()
        device.selection.set(["en", "ar"])
        let gate = Gate()
        device.server.onObjectRequest = { gate.hold() }
        let cycle = try device.cycle()
        let change = Task { await cycle.languageChanged() }
        try await gate.waitUntilHeld()
        let poll = Task { await cycle.run() }
        try await Task.sleep(nanoseconds: 100_000_000)
        gate.open()
        _ = await change.value
        let polled = await poll.value
        XCTAssertEqual(device.server.metaRequests.count, 1, "the run read meta itself")
        XCTAssertNotEqual(polled.outcome, .notDue)
    }

    /// A full disk must not turn every call into a `meta` read.
    func testAFailedSaveStillRespectsTheCadence() async throws {
        let device = try Device(self)
        device.server.publish(try Release.one())
        try await device.runAndActivate()
        device.clock.advance(1800)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: device.store.directory.path)
        addTeardownBlock { [directory = device.store.directory] in
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        }
        let cycle = try device.cycle()
        _ = await cycle.run()
        device.server.resetRequests()
        let again = await cycle.run()
        XCTAssertEqual(again.outcome, .notDue)
        XCTAssertEqual(device.server.metaRequests.count, 0)
    }

    /// An install marked bad is not "known": `meta` naming it is skipped, not treated as unchanged.
    func testABadPendingInstallIsNotTheNewestKnown() async throws {
        let device = try Device(self)
        let one = try Release.one()
        device.server.publish(one)
        try await device.runAndActivate()
        let two = try one.changing(releaseId: 43, slots: [en: Data("\"a\" = \"2\";".utf8)])
        device.server.publish(two)
        device.clock.advance(1800)
        _ = try await device.cycle().run()
        var state = await device.state
        state.badChecksums = [two.checksum]
        try await device.store.save(state)
        device.clock.advance(1800)
        let result2 = try await device.cycle().run()
        XCTAssertEqual(result2.outcome, .skipped)
    }

    /// A language change with no held signature reads `meta` once — not again when the fresh signature is refused too.
    func testALanguageChangeReadsMetaAtMostOnce() async throws {
        let device = try Device(self, locales: ["en"])
        let release = try Release.one()
        device.server.publish(release)
        try await device.runAndActivate()
        var state = await device.state
        state.heldMeta = nil
        try await device.store.save(state)
        device.server.resetRequests()
        let gone = try DeliveryFixtures.error("object-403-cdn-edge")
        device.server.answerObject(hash: try release.hash(of: ar), fileType: "strings", gone, gone, gone)
        device.selection.set(["ar"])
        _ = try await device.cycle().languageChanged()
        XCTAssertEqual(device.server.metaRequests.count, 1)
    }

    /// A failed language change leaves the cadence alone.
    func testAFailedLanguageChangeDoesNotTouchTheCadence() async throws {
        let device = try Device(self, locales: ["en"])
        device.server.publish(try Release.one())
        try await device.runAndActivate()
        let before = await device.state
        device.selection.set(["ar"])
        device.server.goOffline()
        let report = try await device.cycle().languageChanged()
        XCTAssertEqual(report.outcome, .failed)
        let after = await device.state
        XCTAssertEqual(after.lastCheck, before.lastCheck)
        XCTAssertEqual(after.backoffStep, before.backoffStep)
        XCTAssertEqual(after.checkInterval, before.checkInterval)
    }

    /// `Retry-After` on an object answer is honoured like one on `meta`.
    func testRetryAfterOnAnObjectIsHonoured() async throws {
        let device = try Device(self)
        let release = try Release.one()
        device.server.publish(release)
        device.server.answerObject(hash: try release.hash(of: en), fileType: "strings",
                                   CycleFixtures.problem(429, code: "too-many-requests", retryAfter: 900))
        let report = try await device.cycle().run()
        XCTAssertEqual(report.outcome, .failed)
        XCTAssertEqual(report.nextCheckIn, 900)
    }

    private func release(pollAfter: Int) throws -> Release {
        let one = try Release.one()
        return Release(releaseId: one.releaseId, checksum: one.checksum, manifest: one.manifest,
                       metaBody: one.metaBody.merging(["pollAfter": pollAfter]) { $1 }, objects: one.objects)
    }

    /// A server value can be anything; no arithmetic on it may trap, and no wait may exceed a day.
    func testAHugeRetryAfterNeverTrapsAndIsCapped() async throws {
        let device = try Device(self)
        device.server.answerMeta(CycleFixtures.problem(503, code: "unavailable", retryAfter: Int.max))
        let report = try await device.cycle().run()
        XCTAssertEqual(report.outcome, .failed)
        XCTAssertEqual(report.nextCheckIn, 86_400)
        try device.relaunch()
        let result = try await device.cycle().run()
        XCTAssertEqual(result.outcome, .notDue, "the wait was saved")
    }

    /// `pollAfter` has the server's own floor of 60 s; zero or negative never means "poll constantly".
    func testPollAfterHasAFloorOfSixtySeconds() async throws {
        for value in [0, -600, 5] {
            let device = try Device(self)
            device.server.publish(try release(pollAfter: value))
            let report = try await device.cycle().run()
            XCTAssertEqual(report.nextCheckIn, 60, "\(value)")
            device.server.resetRequests()
            _ = try await device.cycle().run()
            XCTAssertEqual(device.server.metaRequests.count, 0, "\(value)")
        }
    }

    /// A manifest or object that keeps failing backs off further each time, even though `meta` itself answers.
    func testBackoffGrowsWhenTheManifestOrAnObjectKeepsFailing() async throws {
        let device = try Device(self)
        let one = try Release.one()
        device.server.publish(one)
        device.server.answerObject(hash: try one.hash(of: en), fileType: "strings",
                                   FakeTransport.Answer(status: 500), FakeTransport.Answer(status: 500), FakeTransport.Answer(status: 500))
        var waits: [TimeInterval] = []
        for _ in 0..<3 {
            let report = try await device.cycle().run()
            waits.append(report.nextCheckIn)
            device.clock.advance(report.nextCheckIn)
        }
        XCTAssertEqual(waits, [60, 120, 240])
        let recovered = try await device.cycle().run()
        guard case .installed = recovered.outcome else { return XCTFail("\(recovered)") }
        XCTAssertEqual(recovered.nextCheckIn, 1800, "recovery resets the backoff")
        let state = await device.state
        XCTAssertEqual(state.backoffStep, 0)
    }

    /// `Retry-After` on a manifest or object 503 is a floor too.
    func testRetryAfterOnAnUnavailableManifestIsHonoured() async throws {
        let device = try Device(self)
        let one = try Release.one()
        device.server.publish(one)
        device.server.answerManifest(CycleFixtures.problem(503, code: "delivery.manifest_unavailable", retryAfter: 600))
        let report = try await device.cycle().run()
        XCTAssertEqual(report.outcome, .failed)
        XCTAssertEqual(report.nextCheckIn, 600)
    }

    /// A language change writes back only what it changed: a bad mark or crash count written meanwhile survives.
    func testALanguageChangeDoesNotOverwriteStateWrittenMeanwhile() async throws {
        let device = try Device(self, locales: ["en"])
        let release = try Release.one()
        device.server.publish(release)
        try await device.runAndActivate()
        let store = device.store
        var held = await store.state
        held.heldMeta = nil
        try await store.save(held)
        device.server.onObjectRequest = {
            let written = DispatchSemaphore(value: 0)
            Task {
                var state = await store.state
                state.launchCrashCount = 2
                state.badChecksums.insert(String(repeating: "f", count: 64))
                try? await store.save(state)
                written.signal()
            }
            written.wait()
        }
        device.selection.set(["ar"])
        _ = try await device.cycle().languageChanged()
        let state = await device.state
        XCTAssertEqual(state.launchCrashCount, 2)
        XCTAssertTrue(state.badChecksums.contains(String(repeating: "f", count: 64)))
    }

    /// A held `meta` that no longer decodes, or names nothing installed, is not worth a 304.
    func testTheETagIsSentOnlyWithAUsableHeldMeta() async throws {
        let device = try Device(self)
        device.server.publish(try Release.one())
        try await device.runAndActivate()
        var state = await device.state
        state.heldMeta = Data("{not meta".utf8)
        try await device.store.save(state)
        device.clock.advance(1800)
        device.server.resetRequests()
        _ = try await device.cycle().run()
        XCTAssertNil(device.server.metaRequests.first?.value(forHTTPHeaderField: "If-None-Match"))
    }

    /// A 304 retries owed slots with the held signature, like a 200 naming the same release.
    func testA304RetriesOwedSlots() async throws {
        let device = try Device(self)
        let release = try Release.one()
        device.server.publish(release)
        let gone = try DeliveryFixtures.error("object-404-slice-not-found")
        device.server.answerObject(hash: try release.hash(of: en), fileType: "strings", gone)
        try await device.runAndActivate()
        device.server.answerMeta(FakeTransport.Answer(status: 304))
        device.clock.advance(1800)
        let report = try await device.cycle().run()
        guard case .installed(let install) = report.outcome else { return XCTFail("\(report)") }
        XCTAssertEqual(install.owedSlots, [])
        XCTAssertEqual(install.releaseId, 42, "the release id is kept")
    }

    /// Bytes that hash to `meta.checksum` but do not decode are rejected, like an unknown schema.
    func testAnUnreadableManifestIsRejected() async throws {
        let device = try Device(self)
        let one = try Release.one()
        let garbage = Data("not a manifest".utf8)
        var meta = one.metaBody
        let checksum = Fixtures.sha256Hex(garbage)
        meta["checksum"] = checksum
        meta["manifestUrl"] = "https://cdn.example.invalid/releases/1/\(checksum)/manifest.json"
        device.server.publish(Release(releaseId: 43, checksum: checksum, manifest: garbage, metaBody: meta, objects: [:]))
        let report = try await device.cycle().run()
        XCTAssertEqual(report.outcome, .rejected(checksum: checksum, .unreadable))
    }

    /// A language change after the clock moved back reports the check as due now, as `run()` would.
    func testALanguageChangeAfterTheClockMovedBackReportsDueNow() async throws {
        let device = try Device(self, locales: ["en", "ar"])
        device.server.publish(try Release.one())
        try await device.runAndActivate()
        device.clock.advance(-31_536_000)
        device.selection.set(["ar"])
        let report = try await device.cycle().languageChanged()
        XCTAssertEqual(report.nextCheckIn, 0)
    }

    /// A cycle's cost grows with the number of slots, not with its square.
    func testALargeReleaseInstallsInLinearTime() async throws {
        let device = try Device(self, locales: (0..<10).map { "l\($0)" })
        let manifestObject = try XCTUnwrap(JSONSerialization.jsonObject(with: Release.one().manifest) as? [String: Any])
        var bundles = try XCTUnwrap(manifestObject["bundles"] as? [String: Any])
        for bundle in 0..<60 { bundles["nsx\(bundle)"] = ["type": "namespace", "name": "n\(bundle)"] }
        var big = try Release.one().changing(releaseId: 43, fields: ["bundles": bundles])
        var bySlot: [Slot: Data?] = [:]
        for bundle in 0..<60 {
            for locale in 0..<10 {
                bySlot[Slot(bundleId: "nsx\(bundle)", locale: "l\(locale)", fileType: "strings")] = Data("\"k\" = \"\(bundle)-\(locale)\";".utf8)
            }
        }
        big = try big.changing(releaseId: 43, slots: bySlot)
        device.server.publish(big)
        let started = Date()
        let report = try await device.cycle().run()
        guard case .installed(let install) = report.outcome else { return XCTFail("\(report)") }
        XCTAssertEqual(install.owedSlots, [])
        XCTAssertLessThan(Date().timeIntervalSince(started), 10)
    }

    /// An owed slot holds the active install's older file; it is still owed, and retried in the next due cycle.
    func testAnOwedSlotCarryingTheActiveFileIsRetried() async throws {
        let device = try Device(self)
        let one = try Release.one()
        device.server.publish(one)
        try await device.runAndActivate()
        let newer = Data("\"app.title\" = \"Tarjim 2\";".utf8)
        let two = try one.changing(releaseId: 43, slots: [en: newer])
        device.server.publish(two)
        device.server.answerObject(hash: Fixtures.sha256Hex(newer), fileType: "strings", try DeliveryFixtures.error("object-404-slice-not-found"))
        device.clock.advance(1800)
        let first = try await device.cycle().run()
        guard case .installed(let carried) = first.outcome else { return XCTFail("\(first)") }
        XCTAssertEqual(carried.owedSlots, [en])
        try await device.store.activate(carried)
        device.clock.advance(1800)
        let second = try await device.cycle().run()
        guard case .installed(let fixed) = second.outcome else { return XCTFail("\(second)") }
        XCTAssertEqual(fixed.owedSlots, [])
        XCTAssertEqual(try device.file(fixed, en), newer)
    }

    /// A language change's own `meta` read failing is not a failed cycle: the cadence stays as it was.
    func testALanguageChangeWhoseMetaReadFailsLeavesTheCadence() async throws {
        let device = try Device(self, locales: ["en"])
        device.server.publish(try Release.one())
        try await device.runAndActivate()
        var state = await device.state
        state.heldMeta = nil
        try await device.store.save(state)
        let before = await device.state
        device.server.answerMeta(FakeTransport.Answer(status: 503))
        device.selection.set(["ar"])
        let report = try await device.cycle().languageChanged()
        XCTAssertEqual(report.outcome, .failed)
        let after = await device.state
        XCTAssertEqual(after.lastCheck, before.lastCheck)
        XCTAssertEqual(after.backoffStep, before.backoffStep)
        XCTAssertEqual(after.checkInterval, before.checkInterval)
    }

    /// Nothing released to the stage (any more) deletes nothing — not the pending install either.
    func testUnreleasedKeepsAPendingInstall() async throws {
        let device = try Device(self)
        device.server.publish(try Release.one())
        _ = try await device.cycle().run()
        let pending = await device.state.pending
        XCTAssertNotNil(pending)
        device.clock.advance(1800)
        device.server.answerMeta(CycleFixtures.problem(404, code: "delivery.stage_unreleased", pollAfter: 600))
        _ = try await device.cycle().run()
        let state = await device.state
        XCTAssertEqual(state.pending, pending)
    }

    private func release(pollAfter: Int, _ base: Release) -> Release {
        Release(releaseId: base.releaseId, checksum: base.checksum, manifest: base.manifest,
                metaBody: base.metaBody.merging(["pollAfter": pollAfter]) { $1 }, objects: base.objects)
    }

    /// `meta` flapping between two releases whose files are gone settles at the floor every time, never at zero.
    func testAFlappingMetaNeverLoopsWithoutDelay() async throws {
        let device = try Device(self)
        let one = try Release.one()
        let two = try one.changing(releaseId: 43, slots: [en: Data("\"a\" = \"2\";".utf8)])
        device.server.publish(two, meta: false)
        device.server.publish(one)
        device.server.answerMeta(one.metaAnswer(), two.metaAnswer(), one.metaAnswer(), two.metaAnswer(), one.metaAnswer(),
                                 two.metaAnswer(), one.metaAnswer())
        let gone = try DeliveryFixtures.error("object-403-cdn-edge")
        device.server.answerObject(hash: try one.hash(of: en), fileType: "strings", gone, gone, gone, gone)
        var waits: [TimeInterval] = []
        for _ in 0..<3 {
            let report = try await device.cycle().run()
            waits.append(report.nextCheckIn)
            let immediately = try await device.cycle().run()
            XCTAssertEqual(immediately.outcome, .notDue)
            device.clock.advance(report.nextCheckIn)
        }
        XCTAssertEqual(waits, [60, 120, 240], "a flapping meta backs off like any failure")
    }

    /// A slot the Store will never write (an unsafe bundle id, a locale differing only in case) is not "missing":
    /// no install is built for it, cycle after cycle.
    func testASlotTheStoreCannotWriteIsNotMissingForever() async throws {
        let device = try Device(self, locales: ["en", "EN"])
        var bundles = try XCTUnwrap(JSONSerialization.jsonObject(with: Release.one().manifest) as? [String: Any])["bundles"] as! [String: Any]
        bundles["com.app"] = ["type": "custom", "name": "dotted"]
        let odd = Slot(bundleId: "com.app", locale: "en", fileType: "strings")
        let twin = Slot(bundleId: "ns7", locale: "EN", fileType: "strings")
        let release = try Release.one().changing(releaseId: 43, slots: [odd: Data("\"x\" = \"y\";".utf8), twin: Data("\"x\" = \"z\";".utf8)],
                                                 fields: ["bundles": bundles])
        device.server.publish(release)
        try await device.runAndActivate()
        for _ in 0..<2 {
            device.clock.advance(1800)
            let report = try await device.cycle().run()
            XCTAssertEqual(report.outcome, .unchanged)
        }
    }

    /// A 304 keeps the last `pollAfter` known; a configuration error takes the one in its body.
    func testA304AndAConfigurationErrorKeepTheirCadence() async throws {
        let device = try Device(self)
        device.server.publish(release(pollAfter: 900, try Release.one()))
        try await device.runAndActivate()
        device.clock.advance(900)
        device.server.answerMeta(FakeTransport.Answer(status: 304))
        let notModified = try await device.cycle().run()
        XCTAssertEqual(notModified.nextCheckIn, 900)
        device.clock.advance(900)
        device.server.answerMeta(CycleFixtures.problem(404, code: "delivery.track_not_found", pollAfter: 1200))
        let missing = try await device.cycle().run()
        XCTAssertEqual(missing.outcome, .configurationError(code: "delivery.track_not_found"))
        XCTAssertEqual(missing.nextCheckIn, 1200)
    }

    /// No wait exceeds a day, whatever `pollAfter` says.
    func testAHugePollAfterIsCappedAtADay() async throws {
        let device = try Device(self)
        device.server.publish(release(pollAfter: 10_000_000, try Release.one()))
        let report = try await device.cycle().run()
        XCTAssertEqual(report.nextCheckIn, 86_400)
    }

    /// A file that fails its hash is the server's content, not an expired signature: no `meta` re-read for it.
    func testAHashMismatchDoesNotReReadMeta() async throws {
        let device = try Device(self)
        let release = try Release.one()
        device.server.publish(release)
        device.server.answerObject(hash: try release.hash(of: en), fileType: "strings", FakeTransport.Answer(status: 200, body: Data("tampered".utf8)))
        let report = try await device.cycle().run()
        guard case .installed(let install) = report.outcome else { return XCTFail("\(report)") }
        XCTAssertEqual(install.owedSlots, [en])
        XCTAssertEqual(device.server.metaRequests.count, 1)
    }

    /// A language change learning the stage moved on builds nothing for the release it left.
    func testALanguageChangeAfterTheStageMovedBuildsNothing() async throws {
        let device = try Device(self, locales: ["en"])
        let one = try Release.one()
        device.server.publish(one)
        try await device.runAndActivate()
        let two = try one.changing(releaseId: 43, slots: [en: Data("\"a\" = \"2\";".utf8)])
        device.server.publish(two)
        device.server.answerObject(hash: try one.hash(of: ar), fileType: "strings", try DeliveryFixtures.error("object-403-cdn-edge"))
        device.selection.set(["en", "ar"])
        let report = try await device.cycle().languageChanged()
        if case .installed = report.outcome { XCTFail("built for the release the stage left") }
        let state = await device.state
        XCTAssertNil(state.pending)
    }

    /// A language change arriving during a cycle waits for it, then works on what the cycle left.
    func testALanguageChangeWaitsForARunningCycle() async throws {
        let device = try Device(self, locales: ["en"])
        device.server.publish(try Release.one())
        let gate = Gate()
        device.server.onObjectRequest = { gate.hold() }
        let cycle = try device.cycle()
        let poll = Task { await cycle.run() }
        try await gate.waitUntilHeld()
        device.selection.set(["en", "ar"])
        let change = Task { await cycle.languageChanged() }
        try await Task.sleep(nanoseconds: 100_000_000)
        gate.open()
        let polled = await poll.value
        let changed = await change.value
        guard case .installed = polled.outcome else { return XCTFail("\(polled)") }
        guard case .installed(let install) = changed.outcome else { return XCTFail("\(changed)") }
        XCTAssertNotNil(try device.file(install, ar), "it worked on what the cycle left")
    }

    /// A locale key the Store will not write as a folder name is never "missing" either.
    func testAnUnsafeLocaleKeyIsNotMissingForever() async throws {
        let device = try Device(self, locales: ["en", "en.x"])
        let odd = Slot(bundleId: "ns7", locale: "en.x", fileType: "strings")
        let release = try Release.one().changing(releaseId: 43, slots: [odd: Data("\"x\" = \"y\";".utf8)])
        device.server.publish(release)
        try await device.runAndActivate()
        device.clock.advance(1800)
        let report = try await device.cycle().run()
        XCTAssertEqual(report.outcome, .unchanged)
    }

    /// Owed slots wait for due cycles; a language change with nothing new to fetch makes no request, however often
    /// it is called.
    func testALanguageChangeLeavesOwedSlotsToDueCycles() async throws {
        let device = try Device(self, locales: ["en"])
        let release = try Release.one()
        device.server.publish(release)
        let gone = try DeliveryFixtures.error("object-403-cdn-edge")
        device.server.answerObject(hash: try release.hash(of: en), fileType: "strings", gone, gone, gone, gone, gone)
        try await device.runAndActivate()
        let owed = await device.state.active?.owedSlots
        XCTAssertEqual(owed, [en])
        device.server.resetRequests()
        for _ in 0..<3 {
            let report = try await device.cycle().languageChanged()
            XCTAssertEqual(report.outcome, .unchanged)
        }
        XCTAssertEqual(device.server.requests.count, 0)
    }

    /// A held `meta` naming another release than the newest install is not used for If-None-Match.
    func testTheETagIsNotSentWhenTheHeldMetaNamesAnotherRelease() async throws {
        let device = try Device(self)
        let one = try Release.one()
        device.server.publish(one)
        try await device.runAndActivate()
        let two = try one.changing(releaseId: 43, slots: [en: Data("\"a\" = \"2\";".utf8)])
        var state = await device.state
        state.heldMeta = try JSONSerialization.data(withJSONObject: two.metaBody)
        try await device.store.save(state)
        device.clock.advance(1800)
        device.server.resetRequests()
        _ = try await device.cycle().run()
        XCTAssertNil(device.server.metaRequests.first?.value(forHTTPHeaderField: "If-None-Match"))
    }
}
