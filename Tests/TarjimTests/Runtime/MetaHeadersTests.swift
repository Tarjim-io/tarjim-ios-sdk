import Foundation
import XCTest
@testable import Tarjim

/// What an update check says about the app: the app-version header on `meta`, and the release and interval in force.
final class MetaHeadersTests: XCTestCase {
    private func token(_ name: String, of request: URLRequest?) -> String? {
        request?.value(forHTTPHeaderField: "User-Agent")?.split(separator: " ")
            .first { $0.hasPrefix("\(name)/") }.map { String($0.dropFirst(name.count + 1)) }
    }

    func testMetaCarriesTheAppVersionCore() async throws {
        let harness = try RuntimeHarness(self)
        harness.server.publish(try Release.one())
        let runtime = try harness.make()
        await runtime.start(foreground: true)
        await runtime.checkNow()
        let meta = try XCTUnwrap(harness.server.metaRequests.first)
        XCTAssertEqual(meta.value(forHTTPHeaderField: "X-Tarjim-App-Version"), "2.3.1")
        XCTAssertEqual(token("app", of: meta), "2.3.1")
        for other in harness.server.requests where !other.url!.path.hasSuffix("/delivery/meta") {
            XCTAssertNil(other.value(forHTTPHeaderField: "X-Tarjim-App-Version"), "\(other.url!)")
        }
    }

    func testAFreshInstallSaysReleaseZeroAndPollZero() async throws {
        let harness = try RuntimeHarness(self)
        harness.server.publish(try Release.one())
        let runtime = try harness.make()
        await runtime.start(foreground: true)
        await runtime.checkNow()
        let first = harness.server.metaRequests.first
        XCTAssertEqual(token("rel", of: first), "0")
        XCTAssertEqual(token("poll", of: first), "0")
    }

    /// The release shown and the interval obeyed: a downloaded release waiting to be shown is not the one named.
    func testLaterChecksNameTheShownReleaseAndTheIntervalObeyed() async throws {
        let harness = try RuntimeHarness(self)
        harness.server.publish(try Release.one())
        let runtime = try harness.make()
        await runtime.start(foreground: true)
        await runtime.checkNow()
        harness.server.publish(try EngineFixtures.release(title: "Tarjim 2", releaseId: 43))
        harness.clock.advance(3600)
        await runtime.checkNow()
        XCTAssertEqual(token("rel", of: harness.server.metaRequests.last), "42")
        XCTAssertEqual(token("poll", of: harness.server.metaRequests.last), "1800")
        harness.clock.advance(3600)
        harness.server.resetRequests()
        await runtime.checkNow()
        XCTAssertEqual(token("rel", of: harness.server.metaRequests.last), "42", "43 is downloaded, not shown")
        _ = await runtime.activatePendingUpdate()
        harness.clock.advance(3600)
        await runtime.checkNow()
        XCTAssertEqual(token("rel", of: harness.server.metaRequests.last), "43")
    }

    /// `poll/` is the interval in force after the SDK's clamp, never the raw value and never a backoff wait.
    func testPollIsTheClampedIntervalNotABackoff() async throws {
        let harness = try RuntimeHarness(self)
        let release = try Release.one().changing(releaseId: 42, fields: [:])
        harness.server.publish(release)
        harness.server.answerMeta(release.metaAnswer(pollAfter: 5))
        let runtime = try harness.make()
        await runtime.start(foreground: true)
        await runtime.checkNow()
        harness.server.answerMeta(CycleFixtures.problem(503, code: "unavailable"))
        harness.clock.advance(120)
        await runtime.checkNow()
        XCTAssertEqual(token("poll", of: harness.server.metaRequests.last), "60")
        harness.server.publish(release)
        harness.clock.advance(3600)
        await runtime.checkNow()
        XCTAssertEqual(token("poll", of: harness.server.metaRequests.last), "60", "the obeyed interval, not the backoff")
    }

    func testTheInstallIdentifierIsOffUnlessTheAppTurnsItOn() async throws {
        let configuration = TarjimConfiguration(projectId: 1, apiKey: "k", host: URL(string: "https://example.invalid")!,
                                                defaultBundle: .namespace("default"), fallbackLanguage: "en")
        XCTAssertFalse(configuration.sendsInstallIdentifier)
    }

    // MARK: Every path that sets the interval or the release

    /// The interval in force is the one the last answer set, whatever kind of answer it was.
    func testPollFollowsTheIntervalAConfigurationErrorSets() async throws {
        let harness = try RuntimeHarness(self)
        harness.server.publish(try Release.one())
        let runtime = try harness.make()
        await runtime.start(foreground: true)
        await runtime.checkNow()
        harness.server.answerMeta(CycleFixtures.problem(403, code: "delivery.key_revoked", pollAfter: 600))
        harness.clock.advance(3600)
        await runtime.checkNow()
        harness.server.publish(try Release.one())
        harness.clock.advance(700)
        await runtime.checkNow()
        XCTAssertEqual(token("poll", of: harness.server.metaRequests.last), "600")
    }

    func testPollFollowsTheIntervalWhileNothingIsReleased() async throws {
        let harness = try RuntimeHarness(self)
        harness.server.answerMeta(CycleFixtures.problem(404, code: "delivery.stage_unreleased"))
        let runtime = try harness.make()
        await runtime.start(foreground: true)
        await runtime.checkNow()
        harness.clock.advance(61)
        await runtime.checkNow()
        XCTAssertEqual(harness.server.metaRequests.count, 2)
        XCTAssertEqual(token("poll", of: harness.server.metaRequests.last), "60")
    }

    /// A backoff of 60 s after a 503 is not the 600 s interval in force.
    func testPollIsNeverTheBackoffWait() async throws {
        let harness = try RuntimeHarness(self)
        let release = try Release.one()
        harness.server.publish(release)
        harness.server.answerMeta(release.metaAnswer(pollAfter: 600))
        let runtime = try harness.make()
        await runtime.start(foreground: true)
        await runtime.checkNow()
        harness.server.answerMeta(CycleFixtures.problem(503, code: "unavailable"))
        harness.clock.advance(700)
        await runtime.checkNow()
        harness.server.answerMeta(release.metaAnswer(pollAfter: 600))
        harness.clock.advance(61)
        await runtime.checkNow()
        XCTAssertEqual(token("poll", of: harness.server.metaRequests.last), "600")
    }

    func testARelaunchSendsWhatItLastKnew() async throws {
        let harness = try RuntimeHarness(self)
        let release = try Release.one()
        harness.server.publish(release)
        harness.server.answerMeta(release.metaAnswer(pollAfter: 900))
        do {
            let runtime = try harness.make()
            await runtime.start(foreground: true)
            await runtime.checkNow()
        }
        harness.server.resetRequests()
        harness.clock.advance(3600)
        let second = try harness.make()
        await second.start(foreground: true)
        await second.checkNow()
        XCTAssertEqual(token("poll", of: harness.server.metaRequests.first), "900")
        XCTAssertEqual(token("rel", of: harness.server.metaRequests.first), "42")
    }

    /// A change of language rebuilds what lookups read; a release still pending is not named.
    func testAPendingReleaseIsNotNamedAfterALanguageChange() async throws {
        let harness = try RuntimeHarness(self)
        harness.server.publish(try Release.one())
        let runtime = try harness.make()
        await runtime.start(foreground: true)
        await runtime.checkNow()
        harness.server.publish(try EngineFixtures.release(title: "Tarjim 2", releaseId: 43))
        harness.clock.advance(3600)
        await runtime.checkNow()
        // A language the install already holds: the snapshot is rebuilt, nothing is activated.
        await runtime.setLanguage("en")
        harness.clock.advance(3600)
        await runtime.checkNow()
        XCTAssertEqual(token("rel", of: harness.server.metaRequests.last), "42")
    }

    /// After two launches cut short, the release is reverted and the one reverted to is named.
    func testAfterARevertTheReleaseRevertedToIsNamed() async throws {
        let harness = try RuntimeHarness(self)
        harness.server.publish(try Release.one())
        do {
            let runtime = try harness.make()
            await runtime.start(foreground: true)
            await runtime.checkNow()
            harness.server.publish(try EngineFixtures.release(title: "Tarjim 2", releaseId: 43))
            harness.clock.advance(3600)
            await runtime.checkNow()
            _ = await runtime.activatePendingUpdate()
        }
        for _ in 0..<2 {
            let cutShort = try harness.make()
            await cutShort.start(foreground: true)
        }
        harness.server.resetRequests()
        harness.clock.advance(3600)
        let last = try harness.make()
        await last.start(foreground: true)
        await last.checkNow()
        XCTAssertEqual(token("rel", of: harness.server.metaRequests.first), "42")
    }

    /// The app's own version string, reduced on the way out: the header the server rejects otherwise.
    func testTheBundleVersionIsReducedBeforeItIsSent() async throws {
        let harness = try RuntimeHarness(self)
        harness.rawAppVersion = "2.1 beta (77)"
        harness.server.publish(try Release.one())
        let runtime = try harness.make()
        await runtime.start(foreground: true)
        await runtime.checkNow()
        XCTAssertEqual(harness.server.metaRequests.first?.value(forHTTPHeaderField: "X-Tarjim-App-Version"), "2.1.0")
        XCTAssertEqual(token("app", of: harness.server.metaRequests.first), "2.1.0")
    }
}
