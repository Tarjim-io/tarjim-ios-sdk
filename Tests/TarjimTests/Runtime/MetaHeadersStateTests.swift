import Foundation
import XCTest
@testable import Tarjim

/// `release` as a relaunch reads it back from the stored state.
final class MetaHeadersStateTests: XCTestCase {
    /// The old token names, mapped to the query parameters that now carry them.
    private func token(_ name: String, of request: URLRequest?) -> String? {
        let parameter = ["app": "appVersion", "rel": "release", "lang": "language",
                         "install": "installId", "ios": "osVersion"][name] ?? name
        return MetaRequest.query(request)[parameter]
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

    /// A state file written by an earlier version, with the interval it used to report, still loads.
    func testAnOlderStateFileStillGivesTheRelease() async throws {
        let harness = try await seeded()
        try editState(harness) { $0["pollInForce"] = nil; $0["lastPollAfter"] = 900 }
        let first = try await relaunch(harness)
        XCTAssertNil(MetaRequest.query(first)["pollSeconds"])
        XCTAssertEqual(token("rel", of: first), "42")
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
