import Foundation
import XCTest
@testable import Tarjim

/// The `User-Agent` names the language selected for Tarjim text (what `locale` reports), read for each request; it can
/// name a language whose files are still downloading.
final class UserAgentLanguageTests: XCTestCase {
    private func language(of request: URLRequest?) -> String? {
        guard let agent = request?.value(forHTTPHeaderField: "User-Agent") else { return nil }
        return agent.split(separator: " ").first { $0.hasPrefix("lang/") }.map { String($0.dropFirst(5)) }
    }

    /// Nothing served yet: the app's language. Then the release's fallback, which is what is served to a French user.
    func testTheUserAgentCarriesTheServedLanguage() async throws {
        let harness = try RuntimeHarness(self)
        harness.appLanguage.value = "fr"
        harness.server.publish(try Release.one())
        let runtime = try harness.make()
        await runtime.start(foreground: true)
        await runtime.checkNow()
        XCTAssertEqual(language(of: harness.server.metaRequests.first), "fr", "nothing was served yet")
        XCTAssertEqual(runtime.locale.identifier, "en")
        harness.clock.advance(3600)
        await runtime.checkNow()
        XCTAssertEqual(harness.server.metaRequests.count, 2)
        XCTAssertEqual(language(of: harness.server.metaRequests.last), "en")
    }

    func testTheUserAgentFollowsTheLanguageTheAppChooses() async throws {
        let harness = try RuntimeHarness(self)
        harness.server.publish(try Release.one())
        let runtime = try harness.make()
        await runtime.start(foreground: true)
        await runtime.checkNow()
        await runtime.setLanguage("ar")
        await EngineFixtures.settle(until: { runtime.locale.identifier == "ar" })
        XCTAssertEqual(runtime.locale.identifier, "ar")
        harness.clock.advance(3600)
        harness.server.resetRequests()
        await runtime.checkNow()
        XCTAssertEqual(language(of: harness.server.metaRequests.last), "ar")
    }
}

/// A runtime nobody holds any more ends, started or not: nothing it hands out keeps it alive.
final class RuntimeLifetimeTests: XCTestCase {
    func testAStartedRuntimeIsFreedOnceReleased() async throws {
        let harness = try RuntimeHarness(self)
        harness.server.publish(try Release.one())
        weak var released: Runtime?
        do {
            let runtime = try harness.make()
            await runtime.start(foreground: true)
            await runtime.checkNow()
            await runtime.becameActive()
            await runtime.resignedActive()
            released = runtime
        }
        await EngineFixtures.settle(until: { released == nil })
        XCTAssertNil(released)
    }
}
