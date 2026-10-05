import Foundation
import XCTest
@testable import Tarjim

final class StoreStagingTests: XCTestCase {
    private let data = Data("\"greeting\" = \"hello\";".utf8)
    private let checksum = String(repeating: "a", count: 64)

    func testAStagedObjectIsNamedByHashAndTypeAndNamesTheStaging() async throws {
        let root = try StoreFixtures.root(for: self)
        let store = try StoreFixtures.store(root)
        let hash = Fixtures.sha256Hex(data)
        try await store.stage(checksum: checksum, hash: hash, fileType: "strings", verifiedBytes: data)
        let file = store.directory.appendingPathComponent("staging/\(checksum)/\(hash).strings")
        XCTAssertEqual(try Data(contentsOf: file), data)
        let staged = await store.stagedObjects(checksum: checksum)
        XCTAssertEqual(staged, ["\(hash).strings"])
        let held = await store.heldObject(hash: hash, fileType: "strings")
        XCTAssertEqual(held?.standardizedFileURL, file.standardizedFileURL)
        let saved = try await StoreFixtures.store(root).state
        XCTAssertEqual(saved.stagingChecksum, checksum, "the staging in use is the one state.json names")
    }

    /// The Store re-checks what it is given: a file whose hash differs never reaches the disk.
    func testBytesThatDoNotMatchTheirHashAreRefused() async throws {
        let root = try StoreFixtures.root(for: self)
        let store = try StoreFixtures.store(root)
        let other = String(repeating: "0", count: 64)
        do {
            try await store.stage(checksum: checksum, hash: other, fileType: "strings", verifiedBytes: data)
            XCTFail("staged mismatched bytes")
        } catch let error as StoreError {
            XCTAssertEqual(error, .hashMismatch)
        }
        let staged = await store.stagedObjects(checksum: checksum)
        XCTAssertEqual(staged, [])
        XCTAssertEqual(try StoreFixtures.files(under: store.directory.appendingPathComponent("staging")), [])
    }

    /// A crash mid-write leaves a file under another name; it must never look held.
    func testAPartialFileIsNotHeldAndItsSlotIsOwed() async throws {
        let root = try StoreFixtures.root(for: self)
        let store = try StoreFixtures.store(root)
        let slot = StoreFixtures.slot()
        let plan = StoreFixtures.plan(checksum: "a", files: [slot: data])
        let hash = Fixtures.sha256Hex(data)
        let staging = store.directory.appendingPathComponent("staging/\(plan.checksum)", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        try data.prefix(5).write(to: staging.appendingPathComponent("\(hash).strings.partial"))
        try data.prefix(5).write(to: staging.appendingPathComponent(".\(hash).strings"))
        let staged = await store.stagedObjects(checksum: plan.checksum)
        XCTAssertEqual(staged, [])
        let held = await store.heldObject(hash: hash, fileType: "strings")
        XCTAssertNil(held)
        let install = try await store.makeInstall(plan)
        XCTAssertEqual(install.owedSlots, [slot])
        XCTAssertNil(store.fileURL(of: install, slot: slot))
    }

    func testARelaunchKeepsTheStagedObjectsOfTheManifestBeingInstalled() async throws {
        let root = try StoreFixtures.root(for: self)
        let hash = Fixtures.sha256Hex(data)
        try await StoreFixtures.store(root).stage(checksum: checksum, hash: hash, fileType: "strings", verifiedBytes: data)
        let relaunched = try StoreFixtures.store(root)
        _ = try await relaunched.cleanup()
        let staged = await relaunched.stagedObjects(checksum: checksum)
        XCTAssertEqual(staged, ["\(hash).strings"])
    }

    func testAFailedStageLeavesTheActiveInstallAlone() async throws {
        let root = try StoreFixtures.root(for: self)
        let store = try StoreFixtures.store(root)
        let slot = StoreFixtures.slot()
        let plan = StoreFixtures.plan(checksum: "a", files: [slot: data])
        try await StoreFixtures.stage(store, plan, [slot: data])
        let install = try await store.makeInstall(plan)
        try await store.activate(install)
        let before = await store.state
        _ = try? await store.stage(checksum: String(repeating: "b", count: 64), hash: String(repeating: "0", count: 64),
                                   fileType: "strings", verifiedBytes: data)
        let after = await store.state
        XCTAssertEqual(after.active, before.active)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(store.fileURL(of: install, slot: slot))), data)
    }
}
