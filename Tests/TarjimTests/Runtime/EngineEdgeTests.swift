import Foundation
import XCTest
@testable import Tarjim

/// The engine's rules at their edges: what may change mid-session, where a revert lands, what stays watched.
final class EngineEdgeTests: XCTestCase {
    private func arabicProcess() throws -> AppProcess {
        let process = try AppProcess(self)
        process.preferences.value = ["ar-LB"]
        process.appLanguage.value = "ar"
        return process
    }

    /// A later release that drops the user's locale: the active install still serves the user, so the download waits
    /// for the next cold start instead of switching the screen to the fallback language.
    func testALaterReleaseDroppingTheUsersLocaleWaits() async throws {
        let process = try arabicProcess()
        process.server.publish(try Release.one())
        await process.engine.launch(foreground: true)
        await process.engine.check()
        XCTAssertEqual(process.string("app.title"), "ترجم")
        var slices = try XCTUnwrap(JSONSerialization.jsonObject(with: Release.one().manifest) as? [String: Any])["slices"] as! [String: [String: Any]]
        for key in Array(slices.keys) { slices[key]?["ar"] = nil }
        let two = try Release.one().changing(releaseId: 43, fields: ["slices": slices])
        process.server.publish(two)
        process.clock.advance(1800)
        let updates = process.recordUpdates()
        let report = await process.engine.check()
        guard case .installed = report.outcome else { return XCTFail("\(report)") }
        await EngineFixtures.settle()
        XCTAssertEqual(updates.value, [.downloaded])
        XCTAssertEqual(process.string("app.title"), "ترجم")
    }

    /// A check that changes nothing announces nothing.
    func testAnUnchangedCheckSendsNoEvent() async throws {
        let process = try AppProcess(self)
        process.server.publish(try Release.one())
        await process.engine.launch(foreground: true)
        await process.engine.check()
        let updates = process.recordUpdates()
        process.clock.advance(1800)
        await process.engine.check()
        await EngineFixtures.settle()
        XCTAssertEqual(updates.value, [])
    }

    func testProbationNeedsTheFullForegroundTime() async throws {
        let process = try AppProcess(self)
        process.server.publish(try Release.one())
        await process.engine.launch(foreground: true)
        await process.engine.check()
        await process.engine.foregroundElapsed(Engine.probationSeconds - 1)
        let open = await process.state
        XCTAssertNotNil(open.probation)
        await process.engine.foregroundElapsed(1)
        let closed = await process.state
        XCTAssertNil(closed.probation)
    }

    /// Time spent in the foreground before an activation does not count toward the new install's probation.
    func testProbationStartsAtTheActivation() async throws {
        let process = try AppProcess(self)
        process.server.publish(try Release.one())
        await process.engine.launch(foreground: true)
        await process.engine.check()
        await process.engine.foregroundElapsed(Engine.probationSeconds * 3)
        process.server.publish(try EngineFixtures.release(title: "Tarjim 2", releaseId: 43))
        process.clock.advance(1800)
        await process.engine.check()
        _ = await process.engine.activatePendingUpdate()
        await process.engine.foregroundElapsed(1)
        let state = await process.state
        XCTAssertEqual(state.probation, state.active?.directory)
    }

    /// A revert lands on an install that is itself watched: if it crashes too, it is reverted in turn.
    func testTheInstallARevertLandsOnIsOnProbation() async throws {
        let process = try AppProcess(self)
        process.server.publish(try Release.one())
        await process.engine.launch(foreground: true)
        await process.engine.check()
        process.server.publish(try EngineFixtures.release(title: "Tarjim 2", releaseId: 43))
        process.clock.advance(1800)
        await process.engine.check()
        try process.relaunch()
        await process.engine.launch(foreground: true)
        for _ in 0..<2 { try process.relaunch(); await process.engine.launch(foreground: true) }
        var state = await process.state
        XCTAssertEqual(state.active?.checksum, try Release.one().checksum)
        XCTAssertEqual(state.probation, state.active?.directory, "the landing install is watched")
        for _ in 0..<2 { try process.relaunch(); await process.engine.launch(foreground: true) }
        state = await process.state
        XCTAssertNil(state.active, "release 1 crashed twice as well: back to the app's own text")
        XCTAssertEqual(process.string("app.title"), "app.title")
    }

    /// A revert never lands on an install marked bad, nor on one whose files are gone.
    func testARevertSkipsABadOrMissingPrevious() async throws {
        for damage in ["bad", "missing"] {
            let process = try AppProcess(self)
            process.server.publish(try Release.one())
            await process.engine.launch(foreground: true)
            await process.engine.check()
            await process.engine.foregroundElapsed(Engine.probationSeconds)
            let one = await process.state.active
            process.server.publish(try EngineFixtures.release(title: "Tarjim 2", releaseId: 43))
            process.clock.advance(1800)
            await process.engine.check()
            try process.relaunch()
            await process.engine.launch(foreground: true)
            var state = await process.state
            if damage == "bad" {
                state.badChecksums.insert(try XCTUnwrap(one).checksum)
                try await process.store.save(state)
            } else {
                try FileManager.default.removeItem(at: process.store.url(of: try XCTUnwrap(one)))
            }
            for _ in 0..<2 { try process.relaunch(); await process.engine.launch(foreground: true) }
            state = await process.state
            XCTAssertNil(state.active, damage)
            XCTAssertNil(state.previous, damage)
            XCTAssertEqual(process.string("app.title"), "app.title", damage)
        }
    }

    /// After a revert nothing is left pending under the bad checksum, and the probation count starts clean.
    func testARevertClearsWhatPointsAtTheBadRelease() async throws {
        let process = try AppProcess(self)
        process.server.publish(try Release.one())
        await process.engine.launch(foreground: true)
        await process.engine.check()
        await process.engine.foregroundElapsed(Engine.probationSeconds)
        let two = try EngineFixtures.release(title: "Tarjim 2", releaseId: 43)
        process.server.publish(two)
        process.clock.advance(1800)
        await process.engine.check()
        try process.relaunch()
        await process.engine.launch(foreground: true)
        var state = await process.state
        let bad = try XCTUnwrap(state.active)
        state.pending = bad
        try await process.store.save(state)
        for _ in 0..<2 { try process.relaunch(); await process.engine.launch(foreground: true) }
        state = await process.state
        XCTAssertNil(state.pending)
        XCTAssertNil(state.previous)
        XCTAssertEqual(state.launchCrashCount, 0)
    }

    /// A probation left open with nothing active (state read back damaged) does not block later activations.
    func testAnOrphanProbationIsCleared() async throws {
        let process = try AppProcess(self)
        var state = await process.state
        state.probation = "7-aaaaaaaa"
        state.launchCrashCount = 1
        try await process.store.save(state)
        try process.relaunch()
        await process.engine.launch(foreground: true)
        state = await process.state
        XCTAssertNil(state.probation)
        XCTAssertEqual(state.launchCrashCount, 0)
    }

    /// The directory lookups read is never removed by cleanup, even once state.json has moved on.
    func testCleanupKeepsWhatTheSnapshotReads() async throws {
        let process = try AppProcess(self)
        process.server.publish(try Release.one())
        await process.engine.launch(foreground: true)
        await process.engine.check()
        let activeNow = await process.state.active
        let served = try XCTUnwrap(activeNow)
        var state = await process.state
        state.active = nil
        state.previous = nil
        try await process.store.save(state)
        _ = try await process.store.cleanup()
        XCTAssertTrue(StoreFixtures.exists(process.store.url(of: served)))
        XCTAssertEqual(process.string("app.title"), "Tarjim")
    }

    /// A selection the active install already holds needs no fetch and announces nothing.
    func testASelectionAlreadyHeldNeedsNoFetch() async throws {
        let process = try AppProcess(self)
        process.preferences.value = ["en-US", "ar-LB"]
        process.server.publish(try Release.one())
        await process.engine.launch(foreground: true)
        await process.engine.check()
        process.server.resetRequests()
        let updates = process.recordUpdates()
        await process.engine.selectionChanged()
        await EngineFixtures.settle()
        XCTAssertEqual(process.server.requests.count, 0)
        XCTAssertEqual(updates.value, [])
    }

    /// Two activations at once still leave lookups reading the install state.json names.
    func testConcurrentActivationsEndOnTheRecordedInstall() async throws {
        let process = try AppProcess(self)
        process.server.publish(try Release.one())
        await process.engine.launch(foreground: true)
        await process.engine.check()
        process.server.publish(try EngineFixtures.release(title: "Tarjim 2", releaseId: 43))
        process.clock.advance(1800)
        await process.engine.check()
        let engine = process.engine!
        async let first = engine.activatePendingUpdate()
        async let second = engine.didBecomeActive(afterBackground: Engine.longBackgroundSeconds)
        _ = await (first, second)
        let state = await process.state
        let active = try XCTUnwrap(state.active)
        XCTAssertEqual(process.snapshots.current.installDirectory?.standardizedFileURL,
                       process.store.url(of: active).standardizedFileURL)
        XCTAssertEqual(process.string("app.title"), "Tarjim 2")
    }

    /// `start()` returns before `launch` finishes; a call arriving meanwhile waits for it, and a revert only ever
    /// condemns the install that was on probation.
    func testCallsDuringLaunchWaitForItAndRevertTheRightInstall() async throws {
        for _ in 0..<10 {
            let process = try AppProcess(self)
            process.server.publish(try Release.one())
            await process.engine.launch(foreground: true)
            await process.engine.check()
            await process.engine.foregroundElapsed(Engine.probationSeconds)
            let two = try EngineFixtures.release(title: "Tarjim 2", releaseId: 43)
            process.server.publish(two)
            process.clock.advance(1800)
            await process.engine.check()
            try process.relaunch()
            await process.engine.launch(foreground: true)
            try process.relaunch()
            await process.engine.launch(foreground: true)
            let three = try EngineFixtures.release(title: "Tarjim 3", releaseId: 44)
            process.server.publish(three)
            process.clock.advance(1800)
            await process.engine.check()
            try process.relaunch()
            let engine = process.engine!
            async let launched: Void = engine.launch(foreground: true)
            async let activated = engine.activatePendingUpdate()
            _ = await (launched, activated)
            let state = await process.state
            XCTAssertTrue(state.badChecksums.contains(two.checksum))
            XCTAssertFalse(state.badChecksums.contains(three.checksum), "the release that never crashed is not condemned")
        }
    }

    /// Writes from the engine and from a running cycle never overwrite each other.
    func testAnEngineWriteDuringADownloadKeepsTheNewPendingInstall() async throws {
        let process = try AppProcess(self)
        process.server.publish(try Release.one())
        await process.engine.launch(foreground: true)
        await process.engine.check()
        process.server.publish(try EngineFixtures.release(title: "Tarjim 2", releaseId: 43))
        process.clock.advance(1800)
        let gate = Gate()
        process.server.onObjectRequest = { gate.hold() }
        let engine = process.engine!
        let checking = Task { await engine.check() }
        try await gate.waitUntilHeld()
        await engine.foregroundElapsed(Engine.probationSeconds)
        gate.open()
        _ = await checking.value
        let state = await process.state
        XCTAssertNotNil(state.pending)
        XCTAssertNil(state.probation)
    }

    /// An active install whose manifest can no longer be read is dropped, and the next check installs the release again.
    func testADamagedActiveManifestIsRepaired() async throws {
        let process = try AppProcess(self)
        process.server.publish(try Release.one())
        await process.engine.launch(foreground: true)
        await process.engine.check()
        await process.engine.foregroundElapsed(Engine.probationSeconds)
        let activeNow = await process.state.active
        let active = try XCTUnwrap(activeNow)
        try Data("{".utf8).write(to: process.store.url(of: active).appendingPathComponent("manifest.json"))
        try process.relaunch()
        await process.engine.launch(foreground: true)
        let dropped = await process.state
        XCTAssertNil(dropped.active)
        process.clock.advance(1800)
        await process.engine.check()
        XCTAssertEqual(process.string("app.title"), "Tarjim")
    }

    func testANonsenseForegroundTimeIsIgnored() async throws {
        let process = try AppProcess(self)
        process.server.publish(try Release.one())
        await process.engine.launch(foreground: true)
        await process.engine.check()
        await process.engine.foregroundElapsed(.nan)
        await process.engine.foregroundElapsed(-100)
        await process.engine.foregroundElapsed(Engine.probationSeconds)
        let state = await process.state
        XCTAssertNil(state.probation)
    }

    /// `.downloaded` means a new release; another locale of the same release is not one.
    func testALanguageSwitchIsNotANewDownload() async throws {
        let process = try AppProcess(self)
        process.server.publish(try Release.one())
        await process.engine.launch(foreground: true)
        await process.engine.check()
        let updates = process.recordUpdates()
        process.appLanguage.value = "ar"
        process.preferences.value = ["ar-LB"]
        await process.engine.selectionChanged()
        await EngineFixtures.settle()
        XCTAssertEqual(updates.value, [.activated])
    }

    /// A process the system launched in the background and the user opened later is a foreground launch from then on.
    func testOpeningABackgroundLaunchedProcessCountsAsALaunch() async throws {
        let process = try AppProcess(self)
        process.server.publish(try Release.one())
        await process.engine.launch(foreground: true)
        await process.engine.check()
        await process.engine.foregroundElapsed(Engine.probationSeconds)
        process.server.publish(try EngineFixtures.release(title: "Tarjim 2", releaseId: 43))
        process.clock.advance(1800)
        await process.engine.check()
        try process.relaunch()
        await process.engine.launch(foreground: false)
        XCTAssertEqual(process.string("app.title"), "Tarjim")
        await process.engine.enteredForeground()
        XCTAssertEqual(process.string("app.title"), "Tarjim 2", "a cold start the user sees")
        await process.engine.enteredForeground()
        let state = await process.state
        XCTAssertEqual(state.launchCrashCount, 0, "only the first foreground counts")
    }

    /// The stored language override decides the selection when the release has it.
    func testTheStoredOverrideDecidesTheSelection() async throws {
        let process = try AppProcess(self)
        process.server.publish(try Release.one())
        var state = await process.state
        state.languageOverride = "ar"
        try await process.store.save(state)
        try process.relaunch()
        await process.engine.launch(foreground: true)
        await process.engine.check()
        XCTAssertEqual(process.string("app.title"), "ترجم")
    }

    /// Before launch has begun, nothing is activated out of turn: launch itself shows a pending install.
    func testActivatingBeforeLaunchDoesNothing() async throws {
        let process = try AppProcess(self)
        process.server.publish(try Release.one())
        await process.engine.launch(foreground: true)
        await process.engine.check()
        process.server.publish(try EngineFixtures.release(title: "Tarjim 2", releaseId: 43))
        process.clock.advance(1800)
        await process.engine.check()
        try process.relaunch()
        let activated = await process.engine.activatePendingUpdate()
        XCTAssertFalse(activated)
        let state = await process.state
        XCTAssertNotNil(state.pending)
    }

    private func oneActiveTwoPending(_ process: AppProcess) async throws {
        process.server.publish(try Release.one())
        await process.engine.launch(foreground: true)
        await process.engine.check()
        await process.engine.foregroundElapsed(Engine.probationSeconds)
        process.server.publish(try EngineFixtures.release(title: "Tarjim 2", releaseId: 43))
        process.clock.advance(1800)
        await process.engine.check()
    }

    /// Two callers activating at once: one activation, one event.
    func testSimultaneousActivationsAnnounceOnce() async throws {
        for _ in 0..<10 {
            let process = try AppProcess(self)
            try await oneActiveTwoPending(process)
            let updates = process.recordUpdates()
            let engine = process.engine!
            async let first = engine.activatePendingUpdate()
            async let second = engine.activatePendingUpdate()
            let results = await [first, second]
            await EngineFixtures.settle()
            XCTAssertEqual(results.filter { $0 }.count, 1)
            XCTAssertEqual(updates.value, [.activated])
        }
    }

    /// A newly activated install starts with no crashes counted against it.
    func testAnActivationStartsACleanCount() async throws {
        let process = try AppProcess(self)
        try await oneActiveTwoPending(process)
        var state = await process.state
        state.launchCrashCount = 1
        try await process.store.save(state)
        _ = await process.engine.activatePendingUpdate()
        state = await process.state
        XCTAssertEqual(state.launchCrashCount, 0)
        XCTAssertEqual(state.probation, state.active?.directory)
    }

    /// Foreground time counted while an activation happens never closes the new install's probation.
    func testForegroundTimeDuringAnActivationDoesNotCloseItsProbation() async throws {
        for _ in 0..<20 {
            let process = try AppProcess(self)
            try await oneActiveTwoPending(process)
            let engine = process.engine!
            async let activated = engine.activatePendingUpdate()
            async let ticked: Void = engine.foregroundElapsed(1)
            _ = await (activated, ticked)
            let state = await process.state
            XCTAssertEqual(state.probation, state.active?.directory)
        }
    }

    /// Before launch, a check and foreground time do nothing: launch decides what is shown and what is counted.
    func testNothingHappensBeforeLaunch() async throws {
        let process = try AppProcess(self)
        process.server.publish(try Release.one())
        await process.engine.launch(foreground: true)
        await process.engine.check()
        try process.relaunch()
        process.clock.advance(1800)
        let report = await process.engine.check()
        XCTAssertEqual(report.outcome, .notDue)
        XCTAssertEqual(process.server.metaRequests.count, 1, "only the first process's check")
        await process.engine.foregroundElapsed(Engine.probationSeconds)
        let state = await process.state
        XCTAssertNotNil(state.probation, "still open: the previous process's launch has not been counted yet")
    }
}
