import Foundation
import XCTest
@testable import Tarjim

/// What an update check says about the app, in the `meta` query: its version and the release it shows.
final class MetaHeadersTests: XCTestCase {
    /// The old token names, mapped to the query parameters that now carry them.
    private func token(_ name: String, of request: URLRequest?) -> String? {
        let parameter = ["app": "appVersion", "rel": "release", "lang": "language",
                         "install": "installId", "ios": "osVersion"][name] ?? name
        return MetaRequest.query(request)[parameter]
    }

    func testMetaCarriesTheAppVersionCoreInItsQueryOnly() async throws {
        let harness = try RuntimeHarness(self)
        harness.server.publish(try Release.one())
        let runtime = try harness.make()
        await runtime.start(foreground: true)
        await runtime.checkNow()
        let meta = try XCTUnwrap(harness.server.metaRequests.first)
        XCTAssertEqual(token("app", of: meta), "2.3.1")
        XCTAssertNil(meta.value(forHTTPHeaderField: "X-Tarjim-App-Version"), "the version travels in the query, not a header")
        XCTAssertEqual(meta.value(forHTTPHeaderField: "User-Agent"), "Tarjim-iOS/0.1.0")
        for other in harness.server.requests where !other.url!.path.hasSuffix("/delivery/meta") {
            XCTAssertNil(MetaRequest.query(other)["appVersion"], "\(other.url!)")
            XCTAssertNil(other.value(forHTTPHeaderField: "X-Tarjim-App-Version"), "\(other.url!)")
        }
    }

    func testAFreshInstallSaysReleaseZero() async throws {
        let harness = try RuntimeHarness(self)
        harness.server.publish(try Release.one())
        let runtime = try harness.make()
        await runtime.start(foreground: true)
        await runtime.checkNow()
        let first = harness.server.metaRequests.first
        XCTAssertEqual(token("rel", of: first), "0")
        XCTAssertNil(MetaRequest.query(first)["pollSeconds"])
    }

    /// The release shown: a downloaded release waiting to be shown is not the one named.
    func testLaterChecksNameTheShownRelease() async throws {
        let harness = try RuntimeHarness(self)
        harness.server.publish(try Release.one())
        let runtime = try harness.make()
        await runtime.start(foreground: true)
        await runtime.checkNow()
        harness.server.publish(try EngineFixtures.release(title: "Tarjim 2", releaseId: 43))
        harness.clock.advance(3600)
        await runtime.checkNow()
        XCTAssertEqual(token("rel", of: harness.server.metaRequests.last), "42")
        harness.clock.advance(3600)
        harness.server.resetRequests()
        await runtime.checkNow()
        XCTAssertEqual(token("rel", of: harness.server.metaRequests.last), "42", "43 is downloaded, not shown")
        _ = await runtime.activatePendingUpdate()
        harness.clock.advance(3600)
        await runtime.checkNow()
        XCTAssertEqual(token("rel", of: harness.server.metaRequests.last), "43")
    }

    func testTheInstallIdentifierIsOnUnlessTheAppTurnsItOff() async throws {
        let configuration = TarjimConfiguration(deliveryURL: DeliveryFixtures.deliveryURL, apiKey: "k",
                                                defaultBundle: .namespace("default"), fallbackLanguage: "en")
        XCTAssertTrue(configuration.sendsInstallIdentifier)
    }

    // MARK: Every path that sets the release

    /// There is no polling interval any more, so none is reported: not after a full answer, an error that names one,
    /// an unreleased stage, a backoff, or a relaunch that reads an interval stored by an earlier version.
    func testNoIntervalIsSentOnAnyPath() async throws {
        let harness = try RuntimeHarness(self)
        let release = try Release.one()
        harness.server.publish(release)
        harness.server.answerMeta(release.metaAnswer(pollAfter: 5))
        let runtime = try harness.make()
        await runtime.start(foreground: true)
        await runtime.checkNow()
        for answer in [release.metaAnswer(pollAfter: 600), CycleFixtures.problem(403, code: "delivery.key_revoked", pollAfter: 600),
                       CycleFixtures.problem(404, code: "delivery.stage_unreleased"), CycleFixtures.problem(503, code: "unavailable"),
                       release.metaAnswer(pollAfter: 900)] {
            harness.server.answerMeta(answer)
            harness.clock.advance(100_000)
            await runtime.checkNow()
        }
        harness.clock.advance(100_000)
        let next = try harness.make()
        await next.start(foreground: true)
        await next.checkNow()
        XCTAssertGreaterThanOrEqual(harness.server.metaRequests.count, 6)
        for request in harness.server.requests {
            XCTAssertNil(MetaRequest.query(request)["pollSeconds"], "\(request.url!)")
            XCTAssertFalse(request.url?.query?.contains("poll") ?? false, "\(request.url!)")
        }
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
        XCTAssertNil(MetaRequest.query(harness.server.metaRequests.first)["pollSeconds"])
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

    /// The app's own version string, reduced on the way out: the server rejects a `meta` without a well-formed one.
    func testTheBundleVersionIsReducedBeforeItIsSent() async throws {
        let harness = try RuntimeHarness(self)
        harness.rawAppVersion = "2.1 beta (77)"
        harness.server.publish(try Release.one())
        let runtime = try harness.make()
        await runtime.start(foreground: true)
        await runtime.checkNow()
        XCTAssertEqual(token("app", of: harness.server.metaRequests.first), "2.1.0")
    }
}
