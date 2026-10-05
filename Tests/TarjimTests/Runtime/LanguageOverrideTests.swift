import Foundation
import XCTest
@testable import Tarjim

/// An in-app language picker: Tarjim text follows the language the app chose, across launches.
final class LanguageOverrideTests: XCTestCase {
    private func englishProcess() async throws -> AppProcess {
        let process = try AppProcess(self)
        process.server.publish(try Release.one())
        await process.engine.launch(foreground: true)
        await process.engine.check()
        XCTAssertEqual(process.string("app.title"), "Tarjim")
        return process
    }

    /// Choosing a language the release has fetches it if needed and serves it at once.
    func testChoosingALanguageServesIt() async throws {
        let process = try await englishProcess()
        let updates = process.recordUpdates()
        await process.engine.setLanguageOverride("ar")
        XCTAssertEqual(process.string("app.title"), "ترجم")
        let selection = await process.engine.selection
        XCTAssertEqual(selection, LocaleSelection(kind: .user, locales: ["ar"]))
        await EngineFixtures.settle()
        XCTAssertEqual(updates.value, [.activated])
    }

    func testTheChoiceSurvivesARelaunch() async throws {
        let process = try await englishProcess()
        await process.engine.setLanguageOverride("ar")
        try process.relaunch()
        await process.engine.launch(foreground: true)
        XCTAssertEqual(process.string("app.title"), "ترجم")
    }

    func testNilFollowsTheAppsLanguageAgain() async throws {
        let process = try await englishProcess()
        await process.engine.setLanguageOverride("ar")
        XCTAssertEqual(process.string("app.title"), "ترجم")
        await process.engine.setLanguageOverride(nil)
        XCTAssertEqual(process.string("app.title"), "Tarjim")
        let state = await process.state
        XCTAssertNil(state.languageOverride)
    }

    /// A language the release lacks is ignored, not erased: a later release that adds it is served in it.
    func testALanguageTheReleaseLacksIsKeptForLater() async throws {
        let process = try await englishProcess()
        await process.engine.setLanguageOverride("fr")
        XCTAssertEqual(process.string("app.title"), "Tarjim")
        let state = await process.state
        XCTAssertEqual(state.languageOverride, "fr")
        let french = Slot(bundleId: "ns7", locale: "fr", fileType: "strings")
        process.server.publish(try Release.one().changing(releaseId: 43, slots: [french: Data("\"app.title\" = \"Tarjim FR\";".utf8)]))
        process.clock.advance(1800)
        await process.engine.check()
        try process.relaunch()
        await process.engine.launch(foreground: true)
        XCTAssertEqual(process.string("app.title"), "Tarjim FR")
    }

    func testTheChoiceIsMatchedLikeAnyLanguage() async throws {
        let process = try await englishProcess()
        await process.engine.setLanguageOverride("AR")
        XCTAssertEqual(process.string("app.title"), "ترجم")
    }

    /// Through the public runtime: `locale` follows the choice.
    func testTheRuntimeForwardsTheChoice() async throws {
        let harness = try RuntimeHarness(self)
        harness.server.publish(try Release.one())
        let runtime = try harness.make()
        await runtime.start(foreground: true)
        await runtime.checkNow()
        await runtime.setLanguage("ar")
        XCTAssertEqual(runtime.string("app.title", bundle: nil), "ترجم")
        XCTAssertEqual(runtime.locale.identifier, "ar")
    }

    /// A choice made right after `start`, before the SDK has finished starting, is kept and applied.
    func testAChoiceMadeBeforeTheStartFinishesIsKept() async throws {
        let harness = try RuntimeHarness(self)
        harness.server.publish(try Release.one())
        let first = try harness.make()
        await first.start(foreground: true)
        await first.checkNow()
        let runtime = try harness.make()
        await runtime.setLanguage("ar")
        await runtime.start(foreground: true)
        XCTAssertEqual(runtime.string("app.title", bundle: nil), "ترجم")
    }

    /// A choice reaching the engine before launch is only stored: launch decides what is shown and what is counted.
    func testAChoiceBeforeLaunchActivatesNothing() async throws {
        let process = try await englishProcess()
        try process.relaunch()
        await process.engine.setLanguageOverride("ar")
        let before = await process.state
        XCTAssertEqual(before.languageOverride, "ar")
        XCTAssertEqual(before.launchCrashCount, 0)
        await process.engine.launch(foreground: true)
        let after = await process.state
        XCTAssertEqual(after.launchCrashCount, 0, "the install shown for the choice starts its own probation clean")
        XCTAssertEqual(after.probation, after.active?.directory)
        XCTAssertEqual(process.string("app.title"), "ترجم")
    }

    /// The main bundle's own lookups follow the choice too.
    func testTheProxyFollowsTheChoice() async throws {
        let harness = try RuntimeHarness(self)
        harness.server.publish(try Release.one())
        let runtime = try harness.make()
        await runtime.start(foreground: true)
        await runtime.checkNow()
        await runtime.setLanguage("ar")
        XCTAssertEqual(harness.appBundle.localizedString(forKey: "app.title", value: nil, table: nil), "ترجم")
    }

    /// A release that drops the chosen language: the app's language is served, and the choice comes back with it.
    func testAChoiceTheReleaseDropsIsServedAgainWhenItReturns() async throws {
        let process = try await englishProcess()
        await process.engine.setLanguageOverride("ar")
        var slices = try XCTUnwrap(JSONSerialization.jsonObject(with: Release.one().manifest) as? [String: Any])["slices"] as! [String: [String: Any]]
        for key in Array(slices.keys) { slices[key]?["ar"] = nil }
        process.server.publish(try Release.one().changing(releaseId: 43, fields: ["slices": slices]))
        process.clock.advance(1800)
        await process.engine.check()
        try process.relaunch()
        await process.engine.launch(foreground: true)
        XCTAssertEqual(process.string("app.title"), "Tarjim")
        let kept = await process.state.languageOverride
        XCTAssertEqual(kept, "ar")
        process.server.publish(try Release.one().changing(releaseId: 44))
        process.clock.advance(1800)
        await process.engine.check()
        try process.relaunch()
        await process.engine.launch(foreground: true)
        XCTAssertEqual(process.string("app.title"), "ترجم")
    }
}
