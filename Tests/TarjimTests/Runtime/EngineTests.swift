import Foundation
import XCTest
@testable import Tarjim

final class EngineActivationTests: XCTestCase {
    func testBeforeAnyInstallLookupsUseTheAppsOwnText() async throws {
        let process = try AppProcess(self)
        await process.engine.launch(foreground: true)
        XCTAssertEqual(process.string("app.only"), "From the app")
        XCTAssertEqual(process.string("app.title"), "app.title")
        let selection = await process.engine.selection
        XCTAssertNil(selection)
    }

    /// Nothing held for the user's locales: the first download is shown as soon as it is complete.
    func testTheFirstDownloadIsShownAtOnce() async throws {
        let process = try AppProcess(self)
        process.server.publish(try Release.one())
        await process.engine.launch(foreground: true)
        let updates = process.recordUpdates()
        let report = await process.engine.check()
        guard case .installed = report.outcome else { return XCTFail("\(report)") }
        XCTAssertEqual(process.string("app.title"), "Tarjim")
        let state = await process.state
        XCTAssertNotNil(state.active)
        XCTAssertNil(state.pending)
        await EngineFixtures.settle()
        XCTAssertEqual(updates.value, [.downloaded, .activated])
        let selection = await process.engine.selection
        XCTAssertEqual(selection, LocaleSelection(kind: .user, locales: ["en"]))
    }

    /// A screen never changes wording under the user: a later download waits for the next cold start.
    func testALaterDownloadWaitsForTheNextColdStart() async throws {
        let process = try AppProcess(self)
        process.server.publish(try Release.one())
        await process.engine.launch(foreground: true)
        await process.engine.check()
        process.server.publish(try EngineFixtures.release(title: "Tarjim 2", releaseId: 43))
        process.clock.advance(1800)
        let updates = process.recordUpdates()
        await process.engine.check()
        XCTAssertEqual(process.string("app.title"), "Tarjim")
        await EngineFixtures.settle()
        XCTAssertEqual(updates.value, [.downloaded])

        try process.relaunch()
        await process.engine.launch(foreground: true)
        XCTAssertEqual(process.string("app.title"), "Tarjim 2")
        let state = await process.state
        XCTAssertNil(state.pending)
    }

    /// A launch the system makes in the background shows what is active and activates nothing.
    func testABackgroundLaunchActivatesNothing() async throws {
        let process = try AppProcess(self)
        try await installOneThenDownloadTwo(process)
        try process.relaunch()
        await process.engine.launch(foreground: false)
        XCTAssertEqual(process.string("app.title"), "Tarjim")
        let state = await process.state
        XCTAssertNotNil(state.pending)
    }

    func testActivatePendingUpdateShowsItNow() async throws {
        let process = try AppProcess(self)
        try await installOneThenDownloadTwo(process)
        let updates = process.recordUpdates()
        let activated = await process.engine.activatePendingUpdate()
        XCTAssertTrue(activated)
        XCTAssertEqual(process.string("app.title"), "Tarjim 2")
        await EngineFixtures.settle()
        XCTAssertEqual(updates.value, [.activated])
        let again = await process.engine.activatePendingUpdate()
        XCTAssertFalse(again, "nothing pending any more")
    }

    /// Back after a long time away: the pending release is shown; after a short absence it still waits.
    func testAReturnAfterALongAbsenceShowsThePendingRelease() async throws {
        let process = try AppProcess(self)
        try await installOneThenDownloadTwo(process)
        await process.engine.didBecomeActive(afterBackground: Engine.longBackgroundSeconds - 1)
        XCTAssertEqual(process.string("app.title"), "Tarjim")
        await process.engine.didBecomeActive(afterBackground: Engine.longBackgroundSeconds)
        XCTAssertEqual(process.string("app.title"), "Tarjim 2")
    }

    func testASecondLaunchCallDoesNothing() async throws {
        let process = try AppProcess(self)
        try await installOneThenDownloadTwo(process)
        await process.engine.launch(foreground: true)
        XCTAssertEqual(process.string("app.title"), "Tarjim", "the pending release waits for the next process")
    }

    /// The installed locales follow the app's language: switching it fetches the held release's other locale and
    /// shows it at once (nothing was held for it).
    func testASelectionChangeFetchesAndShowsTheNewLocale() async throws {
        let process = try AppProcess(self)
        process.server.publish(try Release.one())
        await process.engine.launch(foreground: true)
        await process.engine.check()
        process.appLanguage.value = "ar"
        process.preferences.value = ["ar-LB"]
        await process.engine.selectionChanged()
        XCTAssertEqual(process.string("app.title"), "ترجم")
        let selection = await process.engine.selection
        XCTAssertEqual(selection, LocaleSelection(kind: .user, locales: ["ar"]))
    }

    /// A pending install whose checksum is marked bad is never shown.
    func testABadPendingInstallIsNeverActivated() async throws {
        let process = try AppProcess(self)
        try await installOneThenDownloadTwo(process)
        var state = await process.state
        let pending = try XCTUnwrap(state.pending)
        state.badChecksums.insert(pending.checksum)
        try await process.store.save(state)
        let activated = await process.engine.activatePendingUpdate()
        XCTAssertFalse(activated)
        await process.engine.didBecomeActive(afterBackground: Engine.longBackgroundSeconds)
        try process.relaunch()
        await process.engine.launch(foreground: true)
        XCTAssertEqual(process.string("app.title"), "Tarjim")
    }

    private func installOneThenDownloadTwo(_ process: AppProcess) async throws {
        process.server.publish(try Release.one())
        await process.engine.launch(foreground: true)
        await process.engine.check()
        process.server.publish(try EngineFixtures.release(title: "Tarjim 2", releaseId: 43))
        process.clock.advance(1800)
        await process.engine.check()
        XCTAssertEqual(process.string("app.title"), "Tarjim")
    }
}

/// An update that makes the app crash at launch must not brick it until a reinstall.
final class LaunchCrashRevertTests: XCTestCase {
    /// Two foreground launches in a row that end before probation closes: back to the previous release, which stays.
    func testTwoCrashedLaunchesRevertAndMarkTheReleaseBad() async throws {
        let process = try AppProcess(self)
        let two = try await installTwoAsPendingOverOne(process)
        try process.relaunch()
        await process.engine.launch(foreground: true)
        XCTAssertEqual(process.string("app.title"), "Tarjim 2", "activated, on probation")
        try process.relaunch()
        await process.engine.launch(foreground: true)
        XCTAssertEqual(process.string("app.title"), "Tarjim 2", "one cut-short launch is not enough")
        try process.relaunch()
        await process.engine.launch(foreground: true)
        XCTAssertEqual(process.string("app.title"), "Tarjim", "reverted")
        let state = await process.state
        XCTAssertTrue(state.badChecksums.contains(two.checksum))
        XCTAssertEqual(state.probation, state.active?.directory, "the release reverted to is watched in turn")
        XCTAssertEqual(state.launchCrashCount, 0)

        try process.relaunch()
        await process.engine.launch(foreground: true)
        process.clock.advance(1800)
        let report = await process.engine.check()
        XCTAssertEqual(report.outcome, .skipped, "the bad release is not fetched again while meta names it")
        XCTAssertEqual(process.string("app.title"), "Tarjim")
    }

    /// One launch that stayed in the foreground long enough between two cut-short ones: no revert.
    func testAGoodLaunchInBetweenClosesProbation() async throws {
        let process = try AppProcess(self)
        _ = try await installTwoAsPendingOverOne(process)
        try process.relaunch()
        await process.engine.launch(foreground: true)
        try process.relaunch()
        await process.engine.launch(foreground: true)
        await process.engine.foregroundElapsed(Engine.probationSeconds)
        let closed = await process.state
        XCTAssertNil(closed.probation)
        XCTAssertEqual(closed.launchCrashCount, 0)
        try process.relaunch()
        await process.engine.launch(foreground: true)
        try process.relaunch()
        await process.engine.launch(foreground: true)
        XCTAssertEqual(process.string("app.title"), "Tarjim 2")
    }

    /// A background launch neither counts nor clears.
    func testBackgroundLaunchesDoNotCount() async throws {
        let process = try AppProcess(self)
        _ = try await installTwoAsPendingOverOne(process)
        try process.relaunch()
        await process.engine.launch(foreground: true)
        for _ in 0..<3 {
            try process.relaunch()
            await process.engine.launch(foreground: false)
        }
        let state = await process.state
        XCTAssertEqual(state.launchCrashCount, 0)
        XCTAssertNotNil(state.probation)
        XCTAssertEqual(process.string("app.title"), "Tarjim 2")
    }

    /// The very first install crashing: nothing to go back to but the app's own text.
    func testRevertingTheFirstInstallFallsBackToTheAppsOwnText() async throws {
        let process = try AppProcess(self)
        process.server.publish(try Release.one())
        await process.engine.launch(foreground: true)
        await process.engine.check()
        XCTAssertEqual(process.string("app.title"), "Tarjim")
        for _ in 0..<2 {
            try process.relaunch()
            await process.engine.launch(foreground: true)
        }
        XCTAssertEqual(process.string("app.title"), "app.title")
        XCTAssertEqual(process.string("app.only"), "From the app")
        let state = await process.state
        XCTAssertNil(state.active)
    }

    /// An install shown on a return to the foreground is on probation like one shown at launch.
    func testAnActivationOnReturnIsOnProbation() async throws {
        let process = try AppProcess(self)
        let two = try await installTwoAsPendingOverOne(process)
        try process.relaunch()
        await process.engine.launch(foreground: false)
        await process.engine.didBecomeActive(afterBackground: Engine.longBackgroundSeconds)
        let state = await process.state
        XCTAssertEqual(state.active?.checksum, two.checksum)
        XCTAssertEqual(state.probation, state.active?.directory)
    }

    private func installTwoAsPendingOverOne(_ process: AppProcess) async throws -> Release {
        let two = try EngineFixtures.release(title: "Tarjim 2", releaseId: 43)
        process.server.publish(try Release.one())
        await process.engine.launch(foreground: true)
        await process.engine.check()
        await process.engine.foregroundElapsed(Engine.probationSeconds)
        process.server.publish(two)
        process.clock.advance(1800)
        await process.engine.check()
        return two
    }
}
