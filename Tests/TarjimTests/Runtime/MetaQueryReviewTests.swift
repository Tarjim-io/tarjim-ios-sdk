import Foundation
import XCTest
@testable import Tarjim

/// The identity query end to end: the build number, the install identifier's life, and what a refusal says.
final class MetaQueryReviewTests: XCTestCase {
    private func firstMeta(_ harness: RuntimeHarness, _ configuration: TarjimConfiguration? = nil) async throws -> URLRequest? {
        harness.server.publish(try Release.one())
        let runtime = try harness.make(configuration)
        await runtime.start(foreground: true)
        await runtime.checkNow()
        return harness.server.metaRequests.first
    }

    private func editState(_ harness: RuntimeHarness, _ change: (inout [String: Any]) -> Void) throws {
        let files = FileManager.default.enumerator(at: harness.root, includingPropertiesForKeys: nil)?.allObjects as? [URL] ?? []
        let file = try XCTUnwrap(files.first { $0.lastPathComponent == "state.json" })
        var state = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        change(&state)
        try JSONSerialization.data(withJSONObject: state).write(to: file)
    }

    func testTheAppsBuildNumberIsSent() async throws {
        let harness = try RuntimeHarness(self)
        harness.rawAppBuild = "77"
        let meta = try await firstMeta(harness)
        XCTAssertEqual(MetaRequest.query(meta)["appBuild"], "77")
    }

    /// An empty build number is no build number; a long one is not something a server should store.
    func testAnEmptyOrOverlongBuildNumberIsLeftOut() async throws {
        for build in ["", String(repeating: "9", count: 65)] {
            let harness = try RuntimeHarness(self)
            harness.rawAppBuild = build
            let meta = try await firstMeta(harness)
            XCTAssertNil(MetaRequest.query(meta)["appBuild"], "\(build.count) characters")
            XCTAssertFalse(meta?.url?.query?.contains("appBuild") ?? true)
        }
    }

    /// Turning the identifier off forgets it: turning it on again later starts a new one.
    func testTurningTheIdentifierOffForgetsIt() async throws {
        let harness = try RuntimeHarness(self)
        let firstMeta = try await firstMeta(harness)
        let first = try XCTUnwrap(MetaRequest.query(firstMeta)["installId"])
        harness.server.resetRequests()
        harness.clock.advance(3600)
        let off = try harness.make(harness.configuration(sendsInstallIdentifier: false))
        await off.start(foreground: true)
        await off.checkNow()
        XCTAssertNil(MetaRequest.query(harness.server.metaRequests.first)["installId"])
        harness.server.resetRequests()
        harness.clock.advance(3600)
        let on = try harness.make()
        await on.start(foreground: true)
        await on.checkNow()
        let second = try XCTUnwrap(MetaRequest.query(harness.server.metaRequests.first)["installId"])
        XCTAssertNotEqual(second, first)
    }

    /// A stored identifier that is not one the SDK makes (a damaged or edited state file) is replaced, not sent.
    func testAStoredIdentifierThatIsNotAUUIDIsReplaced() async throws {
        let harness = try RuntimeHarness(self)
        _ = try await firstMeta(harness)
        try editState(harness) { $0["installIdentifier"] = String(repeating: "x", count: 80) }
        harness.server.resetRequests()
        harness.clock.advance(3600)
        let next = try harness.make()
        await next.start(foreground: true)
        await next.checkNow()
        let sent = try XCTUnwrap(MetaRequest.query(harness.server.metaRequests.first)["installId"])
        XCTAssertNotNil(UUID(uuidString: sent), sent)
    }

    /// A refused app version is not the key's fault, and the report must not say it is.
    func testARefusedAppVersionIsReportedAsSuch() async throws {
        let harness = try RuntimeHarness(self)
        harness.server.answerMeta(CycleFixtures.problem(400, code: "delivery.app_version_required"))
        let runtime = try harness.make()
        await runtime.start(foreground: true)
        await runtime.checkNow()
        await EngineFixtures.settle(until: { !harness.reports.value.isEmpty })
        let report = try XCTUnwrap(harness.reports.value.first)
        XCTAssertEqual(report.kind, .configuration(code: "delivery.app_version_required"))
        XCTAssertFalse(report.message.lowercased().contains("key"), report.message)
        XCTAssertTrue(report.message.lowercased().contains("version"), report.message)
    }

    /// Each parameter appears once.
    func testNoParameterIsSentTwice() async throws {
        let harness = try RuntimeHarness(self)
        harness.rawAppBuild = "77"
        let sent = try await firstMeta(harness)
        let meta = try XCTUnwrap(sent)
        let names = URLComponents(url: try XCTUnwrap(meta.url), resolvingAgainstBaseURL: false)?.queryItems?.map(\.name) ?? []
        XCTAssertEqual(names, ["appVersion", "platform", "sdkVersion", "release", "pollSeconds", "language", "osVersion", "installId",
                               "appBuild"])
    }
}
