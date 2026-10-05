import Foundation
import XCTest
@testable import Tarjim

final class StoreStateTests: XCTestCase {
    private func stateFile(_ store: Store) -> URL {
        store.directory.appendingPathComponent("state.json")
    }

    func testSaveIsReadBackByAnotherStoreOverTheSameRoot() async throws {
        let root = try StoreFixtures.root(for: self)
        var state = StoreState(sdkVersion: StoreFixtures.sdkVersion)
        state.lastCheck = Date(timeIntervalSince1970: 1_790_000_000)
        state.lastPollAfter = 1800
        state.backoffStep = 2
        state.nextInstallNumber = 9
        state.stagingChecksum = String(repeating: "a", count: 64)
        state.active = InstallRecord(directory: "8-aaaaaaaa", checksum: String(repeating: "a", count: 64), releaseId: 3,
                                     owedSlots: [StoreFixtures.slot()])
        state.badChecksums = [String(repeating: "c", count: 64)]
        state.languageOverride = "ar"
        state.deliveredReports = ["schema:2"]
        try await StoreFixtures.store(root).save(state)
        let reread = try StoreFixtures.store(root)
        let loaded = await reread.state
        XCTAssertEqual(loaded, state)
    }

    /// An unreadable `state.json` must never crash the app: the Store starts empty and can save again.
    func testAnUnreadableStateStartsFreshAndIsReplaced() async throws {
        let root = try StoreFixtures.root(for: self)
        let first = try StoreFixtures.store(root)
        try Data("{not json".utf8).write(to: stateFile(first))
        let store = try StoreFixtures.store(root)
        let loaded = await store.state
        XCTAssertEqual(loaded, StoreState(sdkVersion: StoreFixtures.sdkVersion))
        var next = loaded
        next.backoffStep = 1
        try await store.save(next)
        let reread = try await StoreFixtures.store(root).state
        XCTAssertEqual(reread.backoffStep, 1)
    }

    /// A later SDK's format is not guessed at; this SDK starts empty.
    func testAnotherFormatVersionStartsFresh() async throws {
        let root = try StoreFixtures.root(for: self)
        let store = try StoreFixtures.store(root)
        var state = StoreState(sdkVersion: StoreFixtures.sdkVersion)
        state.nextInstallNumber = 5
        try await store.save(state)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: stateFile(store))) as? [String: Any])
        XCTAssertEqual(object["formatVersion"] as? Int, 1)
        object["formatVersion"] = 2
        try JSONSerialization.data(withJSONObject: object).write(to: stateFile(store))
        let reread = try await StoreFixtures.store(root).state
        XCTAssertEqual(reread.nextInstallNumber, 1)
        XCTAssertEqual(reread.formatVersion, 1)
    }

    func testSaveLeavesOnlyStateJSONBehind() async throws {
        let root = try StoreFixtures.root(for: self)
        let store = try StoreFixtures.store(root)
        var state = StoreState(sdkVersion: StoreFixtures.sdkVersion)
        state.deliveredReports = Set((0..<200).map { "report-\($0)" })
        try await store.save(state)
        state.deliveredReports = []
        try await store.save(state)
        XCTAssertEqual(try StoreFixtures.files(under: store.directory), ["state.json"])
        let reread = try await StoreFixtures.store(root).state
        XCTAssertEqual(reread, state, "a shorter save replaced the longer one completely")
    }

    /// A newer SDK may read what an older one rejected; a bad (crashing) checksum stays bad.
    func testAnSDKUpgradeClearsRejectedChecksumsButNotBadOnes() async throws {
        let root = try StoreFixtures.root(for: self)
        var state = StoreState(sdkVersion: "0.1.0")
        state.rejectedChecksums = [String(repeating: "a", count: 64)]
        state.badChecksums = [String(repeating: "b", count: 64)]
        try await StoreFixtures.store(root, sdkVersion: "0.1.0").save(state)

        let same = try await StoreFixtures.store(root, sdkVersion: "0.1.0").state
        XCTAssertEqual(same.rejectedChecksums, state.rejectedChecksums)

        let upgraded = try await StoreFixtures.store(root, sdkVersion: "0.2.0").state
        XCTAssertEqual(upgraded.rejectedChecksums, [])
        XCTAssertEqual(upgraded.badChecksums, state.badChecksums)
        XCTAssertEqual(upgraded.sdkVersion, "0.2.0")
    }

    /// A clock moved forward and back must not stop polling: a last check in the future is due now.
    func testIsCheckDue() {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        var state = StoreState(sdkVersion: StoreFixtures.sdkVersion)
        XCTAssertTrue(state.isCheckDue(now: now, pollAfter: 1800), "never checked")
        state.lastCheck = now.addingTimeInterval(-1799)
        XCTAssertFalse(state.isCheckDue(now: now, pollAfter: 1800))
        state.lastCheck = now.addingTimeInterval(-1800)
        XCTAssertTrue(state.isCheckDue(now: now, pollAfter: 1800))
        state.lastCheck = now.addingTimeInterval(3600)
        XCTAssertTrue(state.isCheckDue(now: now, pollAfter: 1800), "a last check in the future")
    }
}

final class StoreIdentifierTests: XCTestCase {
    private let host = URL(string: "https://api.example.invalid")!

    func testDiffersByKeyHostAndProjectAndIsStable() {
        let base = StoreIdentifier.make(host: host, projectId: 1, apiKey: "key-a")
        XCTAssertEqual(base, StoreIdentifier.make(host: host, projectId: 1, apiKey: "key-a"))
        XCTAssertNotEqual(base, StoreIdentifier.make(host: host, projectId: 1, apiKey: "key-b"))
        XCTAssertNotEqual(base, StoreIdentifier.make(host: host, projectId: 2, apiKey: "key-a"))
        XCTAssertNotEqual(base, StoreIdentifier.make(host: URL(string: "https://other.example.invalid")!, projectId: 1, apiKey: "key-a"))
    }

    /// It names a directory, so it must be a safe path component that does not reveal the key.
    func testIsThirtyTwoLowercaseHexCharactersWithoutTheKey() {
        let id = StoreIdentifier.make(host: host, projectId: 1, apiKey: "secret-key")
        XCTAssertEqual(id.count, 32)
        XCTAssertTrue(id.allSatisfy { "0123456789abcdef".contains($0) }, id)
        XCTAssertFalse(id.contains("secret"))
    }
}
