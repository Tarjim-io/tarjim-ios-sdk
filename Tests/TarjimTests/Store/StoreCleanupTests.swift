import Foundation
import XCTest
@testable import Tarjim

final class StoreCleanupTests: XCTestCase {
    private let slot = StoreFixtures.slot()

    private func installed(_ store: Store, _ checksum: Character) async throws -> InstallRecord {
        let data = Data("\"k\" = \"\(checksum)\";".utf8)
        let plan = StoreFixtures.plan(checksum: checksum, files: [slot: data])
        try await StoreFixtures.stage(store, plan, [slot: data])
        return try await store.makeInstall(plan)
    }

    private func relative(_ store: Store, _ path: String) -> String {
        "v1/\(StoreFixtures.identifier)/\(path)"
    }

    func testCleanupRemovesEveryInstallNothingNames() async throws {
        let root = try StoreFixtures.root(for: self)
        let store = try StoreFixtures.store(root)
        let a = try await installed(store, "a")
        let b = try await installed(store, "b")
        let c = try await installed(store, "c")
        let crashed = try await installed(store, "d")
        try await store.activate(a)
        try await store.activate(b)
        try await store.setPending(c)
        // A build nothing recorded is a crash's leftover only from the NEXT launch's point of view.
        let removed = try await StoreFixtures.store(root).cleanup()
        XCTAssertTrue(removed.contains(relative(store, "installs/\(crashed.directory)")), "\(removed)")
        XCTAssertFalse(StoreFixtures.exists(store.url(of: crashed)))
        for kept in [a, b, c] {
            XCTAssertTrue(StoreFixtures.exists(store.url(of: kept)), kept.directory)
            XCTAssertNotNil(store.fileURL(of: kept, slot: slot))
        }
    }

    func testCleanupRemovesStagingNothingNamesAndLeftoverBuilds() async throws {
        let root = try StoreFixtures.root(for: self)
        let store = try StoreFixtures.store(root)
        let old = Data("old".utf8)
        let current = Data("current".utf8)
        let oldChecksum = String(repeating: "a", count: 64)
        let currentChecksum = String(repeating: "b", count: 64)
        try await store.stage(checksum: oldChecksum, hash: Fixtures.sha256Hex(old), fileType: "strings", verifiedBytes: old)
        try await store.stage(checksum: currentChecksum, hash: Fixtures.sha256Hex(current), fileType: "strings", verifiedBytes: current)
        let leftover = store.directory.appendingPathComponent("staging/\(currentChecksum)/build-7", isDirectory: true)
        try FileManager.default.createDirectory(at: leftover, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: leftover.appendingPathComponent("manifest.json"))

        let removed = try await store.cleanup()
        XCTAssertEqual(Set(removed), [relative(store, "staging/\(oldChecksum)"), relative(store, "staging/\(currentChecksum)/build-7")])
        let staged = await store.stagedObjects(checksum: currentChecksum)
        XCTAssertEqual(staged, ["\(Fixtures.sha256Hex(current)).strings"])
    }

    /// Files downloaded with one key are never served after the app moves to another.
    func testCleanupRemovesOtherStoresAndOtherFormats() async throws {
        let root = try StoreFixtures.root(for: self)
        let tarjim = root.appendingPathComponent("Tarjim", isDirectory: true)
        let sibling = try StoreFixtures.store(root, identifier: "ffffffffffffffffffffffffffffffff")
        _ = try await installed(sibling, "a")
        try FileManager.default.createDirectory(at: tarjim.appendingPathComponent("v0/x", isDirectory: true), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: tarjim.appendingPathComponent("stray.txt"))

        let store = try StoreFixtures.store(root)
        let own = try await installed(store, "b")
        try await store.activate(own)
        let removed = try await store.cleanup()
        XCTAssertEqual(Set(removed), ["v1/ffffffffffffffffffffffffffffffff", "v0", "stray.txt"])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: tarjim.path), ["v1"])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: tarjim.appendingPathComponent("v1").path),
                       [StoreFixtures.identifier])
        XCTAssertTrue(StoreFixtures.exists(store.url(of: own)))
    }

    /// The lookup snapshot of this process may still read an install state.json has moved past.
    func testCleanupKeepsAProtectedInstall() async throws {
        let root = try StoreFixtures.root(for: self)
        let store = try StoreFixtures.store(root)
        let served = try await installed(store, "a")
        try await store.activate(served)
        for next: Character in ["b", "c"] {
            try await store.activate(try await installed(store, next))
        }
        await store.protect(served)
        let removed = try await store.cleanup()
        XCTAssertFalse(removed.contains { $0.hasSuffix("installs/\(served.directory)") }, "\(removed)")
        XCTAssertTrue(StoreFixtures.exists(store.url(of: served)), "no longer named by state.json, still read by the snapshot")
    }

    func testCleanupOfATidyStoreRemovesNothing() async throws {
        let root = try StoreFixtures.root(for: self)
        let store = try StoreFixtures.store(root)
        let install = try await installed(store, "a")
        try await store.activate(install)
        let first = try await store.cleanup()
        XCTAssertEqual(first, [])
        let second = try await store.cleanup()
        XCTAssertEqual(second, [])
    }
}
