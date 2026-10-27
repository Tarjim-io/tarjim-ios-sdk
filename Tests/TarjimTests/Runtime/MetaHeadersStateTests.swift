import Foundation
import XCTest
@testable import Tarjim

/// `poll/` and `rel/` as a relaunch reads them back from the stored state, and across answers of every kind.
final class MetaHeadersStateTests: XCTestCase {
    private func token(_ name: String, of request: URLRequest?) -> String? {
        request?.value(forHTTPHeaderField: "User-Agent")?.split(separator: " ")
            .first { $0.hasPrefix("\(name)/") }.map { String($0.dropFirst(name.count + 1)) }
    }

    private func editState(_ harness: RuntimeHarness, _ change: (inout [String: Any]) -> Void) throws {
        let files = FileManager.default.enumerator(at: harness.root, includingPropertiesForKeys: nil)?.allObjects as? [URL] ?? []
        let file = try XCTUnwrap(files.first { $0.lastPathComponent == "state.json" })
        var state = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        change(&state)
        try JSONSerialization.data(withJSONObject: state).write(to: file)
    }

    /// Release one shown, by a process that has ended.
    private func seeded() async throws -> RuntimeHarness {
        let harness = try RuntimeHarness(self)
        harness.server.publish(try Release.one())
        let runtime = try harness.make()
        await runtime.start(foreground: true)
        await runtime.checkNow()
        return harness
    }

    /// The first `meta` of a new process, a day later.
    private func relaunch(_ harness: RuntimeHarness) async throws -> URLRequest? {
        harness.server.resetRequests()
        harness.clock.advance(100_000)
        let runtime = try harness.make()
        await runtime.start(foreground: true)
        await runtime.checkNow()
        return harness.server.metaRequests.first
    }

    /// A state file written before the interval in force was stored: the last `pollAfter` stands in for it.
    func testAnOlderStateFileStillGivesThePollAndRelease() async throws {
        let harness = try await seeded()
        try editState(harness) { $0["pollInForce"] = nil; $0["lastPollAfter"] = 900 }
        let first = try await relaunch(harness)
        XCTAssertEqual(token("poll", of: first), "900")
        XCTAssertEqual(token("rel", of: first), "42")
    }

    /// A damaged value never leaves the SDK's own bounds.
    func testAStoredIntervalIsClampedWhenReadBack() async throws {
        for (stored, sent) in [(5, "60"), (-7, "60"), (0, "60"), (10_000_000, "86400")] {
            let harness = try await seeded()
            try editState(harness) { $0["pollInForce"] = stored }
            let first = try await relaunch(harness)
            XCTAssertEqual(token("poll", of: first), sent, "\(stored)")
        }
    }

    func testTheIntervalAConfigurationErrorSetSurvivesARelaunch() async throws {
        let harness = try await seeded()
        let runtime = try harness.make()
        await runtime.start(foreground: true)
        harness.server.answerMeta(CycleFixtures.problem(403, code: "delivery.key_revoked", pollAfter: 600))
        harness.clock.advance(3600)
        await runtime.checkNow()
        harness.server.publish(try Release.one())
        harness.server.resetRequests()
        harness.clock.advance(700)
        let next = try harness.make()
        await next.start(foreground: true)
        await next.checkNow()
        XCTAssertEqual(token("poll", of: harness.server.metaRequests.first), "600")
    }

    /// A good answer after an error sets the interval again.
    func testAGoodAnswerAfterAnErrorSetsTheIntervalAgain() async throws {
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
        harness.clock.advance(3600)
        await runtime.checkNow()
        XCTAssertEqual(token("poll", of: harness.server.metaRequests.last), "1800")
    }

    /// Reporting the interval changes nothing about when checks run.
    func testTheReportedIntervalDoesNotChangeTheSchedule() async throws {
        let harness = try RuntimeHarness(self)
        let release = try Release.one()
        harness.server.publish(release)
        let runtime = try harness.make()
        await runtime.start(foreground: true)
        await runtime.checkNow()
        harness.server.answerMeta(CycleFixtures.problem(403, code: "delivery.key_revoked", pollAfter: 600))
        harness.clock.advance(3600)
        await runtime.checkNow()
        harness.server.answerMeta(.json(304, [:], headers: [:]))
        harness.clock.advance(700)
        let report = await runtime.checkNow()
        XCTAssertEqual(report.nextCheckIn, 1800, "a 304 keeps the cadence of the last full answer")
    }
}
