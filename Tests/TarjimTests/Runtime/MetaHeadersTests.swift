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
}
