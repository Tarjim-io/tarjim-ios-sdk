import Foundation
import XCTest
@testable import Tarjim

final class StoreInstallTests: XCTestCase {
    private let one = Data("\"k\" = \"one\";".utf8)
    private let two = Data("\"k\" = \"two\";".utf8)
    private let three = Data("\"k\" = \"three\";".utf8)
    private let slot = StoreFixtures.slot()
    private let other = StoreFixtures.slot("ns12", "en", "strings")

    private func installed(_ store: Store, _ checksum: Character, _ files: [Slot: Data], releaseId: Int? = nil) async throws -> InstallRecord {
        let plan = StoreFixtures.plan(checksum: checksum, releaseId: releaseId, files: files)
        try await StoreFixtures.stage(store, plan, files)
        return try await store.makeInstall(plan)
    }

    func testInstallDirectoriesNeverRepeat() async throws {
        let root = try StoreFixtures.root(for: self)
        let store = try StoreFixtures.store(root)
        let first = try await installed(store, "a", [slot: one])
        let second = try await installed(store, "a", [slot: one])
        XCTAssertEqual(first.directory, "1-aaaaaaaa")
        XCTAssertEqual(second.directory, "2-aaaaaaaa")
        let next = await store.state.nextInstallNumber
        XCTAssertEqual(next, 3)
    }

    func testTheNumberSurvivesCleanupAndARelaunch() async throws {
        let root = try StoreFixtures.root(for: self)
        let store = try StoreFixtures.store(root)
        _ = try await installed(store, "a", [slot: one])
        let kept = try await installed(store, "b", [slot: two])
        try await store.activate(kept)
        let relaunched = try StoreFixtures.store(root)
        _ = try await relaunched.cleanup()
        XCTAssertFalse(StoreFixtures.exists(store.directory.appendingPathComponent("installs/1-aaaaaaaa")))
        let third = try await installed(relaunched, "c", [slot: three])
        XCTAssertEqual(third.directory, "3-cccccccc")
    }

    /// The process may still read an install whose number a rolled-back or unreadable state.json no
    /// longer remembers; that path must not be reused.
    func testANumberNeverRepeatsInAProcessEvenWhenStateGoesBack() async throws {
        let root = try StoreFixtures.root(for: self)
        let store = try StoreFixtures.store(root)
        let first = try await installed(store, "a", [slot: one])
        var rolledBack = await store.state
        rolledBack.nextInstallNumber = 1
        try await store.save(rolledBack)
        let second = try await installed(store, "a", [slot: one])
        XCTAssertNotEqual(second.directory, first.directory)

        try Data("garbage".utf8).write(to: store.directory.appendingPathComponent("state.json"))
        let relaunched = try StoreFixtures.store(root)
        let third = try await installed(relaunched, "a", [slot: one])
        XCTAssertFalse([first.directory, second.directory].contains(third.directory), third.directory)
    }

    func testMakeInstallNeverWritesIntoAnExistingDirectory() async throws {
        let root = try StoreFixtures.root(for: self)
        let store = try StoreFixtures.store(root)
        let squatter = store.directory.appendingPathComponent("installs/1-aaaaaaaa", isDirectory: true)
        try FileManager.default.createDirectory(at: squatter, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: squatter.appendingPathComponent("sentinel"))
        let install = try await installed(store, "a", [slot: one])
        XCTAssertNotEqual(install.directory, "1-aaaaaaaa")
        XCTAssertEqual(try StoreFixtures.files(under: squatter), ["sentinel"])
    }

    func testMakeInstallActivatesNothing() async throws {
        let root = try StoreFixtures.root(for: self)
        let store = try StoreFixtures.store(root)
        _ = try await installed(store, "a", [slot: one])
        let state = await store.state
        XCTAssertNil(state.active)
        XCTAssertNil(state.pending)
        XCTAssertNil(state.previous)
    }

    func testActivationKeepsThePreviousInstallAndClearsAMatchingPending() async throws {
        let root = try StoreFixtures.root(for: self)
        let store = try StoreFixtures.store(root)
        let a = try await installed(store, "a", [slot: one])
        let b = try await installed(store, "b", [slot: two])
        try await store.activate(a)
        try await store.setPending(b)
        var state = await store.state
        XCTAssertEqual(state.pending, b)
        try await store.activate(b)
        try await store.activate(b)
        state = await store.state
        XCTAssertEqual(state.active, b)
        XCTAssertEqual(state.previous, a, "activating the same install twice keeps the real previous one")
        XCTAssertNil(state.pending)
        let reread = try await StoreFixtures.store(root).state
        XCTAssertEqual(reread, state)
        try await store.setPending(nil)
    }

    /// One unfetchable file must neither block the other slots nor blank its own slot.
    func testAnOwedSlotKeepsTheActiveInstallsFileAndTheRestIsReused() async throws {
        let root = try StoreFixtures.root(for: self)
        let store = try StoreFixtures.store(root)
        let active = try await installed(store, "a", [slot: one, other: two])
        try await store.activate(active)
        let plan = StoreFixtures.plan(checksum: "b", files: [slot: three, other: two])
        let install = try await store.makeInstall(plan)
        XCTAssertEqual(install.owedSlots, [slot])
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(store.fileURL(of: install, slot: slot))), one)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(store.fileURL(of: install, slot: other))), two, "reused by hash from the install on disk")
    }

    func testAnOwedSlotWithNoActiveFileIsAbsent() async throws {
        let root = try StoreFixtures.root(for: self)
        let store = try StoreFixtures.store(root)
        let plan = StoreFixtures.plan(checksum: "a", files: [slot: one, other: two])
        try await StoreFixtures.stage(store, plan, [other: two])
        let install = try await store.makeInstall(plan)
        XCTAssertEqual(install.owedSlots, [slot])
        XCTAssertNil(store.fileURL(of: install, slot: slot))
        XCTAssertFalse(StoreFixtures.exists(store.url(of: install).appendingPathComponent("ns7.bundle/ar.lproj/Localizable.strings")))
        XCTAssertNotNil(store.fileURL(of: install, slot: other))
    }

    /// An install that crashed the app is never a source, not even for an identical hash.
    func testABadInstallIsNeverASource() async throws {
        let root = try StoreFixtures.root(for: self)
        let store = try StoreFixtures.store(root)
        let bad = try await installed(store, "a", [slot: one])
        try await store.activate(bad)
        var state = await store.state
        state.badChecksums = [bad.checksum]
        state.stagingChecksum = nil
        try await store.save(state)
        _ = try await store.cleanup()
        let held = await store.heldObject(hash: Fixtures.sha256Hex(one), fileType: "strings")
        XCTAssertNil(held)
        let install = try await store.makeInstall(StoreFixtures.plan(checksum: "b", files: [slot: one]))
        XCTAssertEqual(install.owedSlots, [slot])
        XCTAssertNil(store.fileURL(of: install, slot: slot), "nor is the bad active install's file taken")
    }

    /// A rollback to a release whose file is still on disk takes that file, not the withdrawn one.
    func testARollbackTakesTheRightFileFromDisk() async throws {
        let root = try StoreFixtures.root(for: self)
        let store = try StoreFixtures.store(root)
        let r1 = try await installed(store, "a", [slot: one], releaseId: 1)
        try await store.activate(r1)
        let r2 = try await installed(store, "b", [slot: two], releaseId: 2)
        try await store.activate(r2)
        _ = try await store.cleanup()
        let rollback = try await store.makeInstall(StoreFixtures.plan(checksum: "a", releaseId: 1, files: [slot: one]))
        XCTAssertEqual(rollback.owedSlots, [])
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(store.fileURL(of: rollback, slot: slot))), one)
    }

    func testHeldObjectsAreFoundInInstallsAfterARelaunch() async throws {
        let root = try StoreFixtures.root(for: self)
        let store = try StoreFixtures.store(root)
        let install = try await installed(store, "a", [slot: one])
        try await store.activate(install)
        var state = await store.state
        state.stagingChecksum = nil
        try await store.save(state)
        let relaunched = try StoreFixtures.store(root)
        _ = try await relaunched.cleanup()
        let held = await relaunched.heldObject(hash: Fixtures.sha256Hex(one), fileType: "strings")
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(held)), one)
        let none = await relaunched.heldObject(hash: Fixtures.sha256Hex(one), fileType: "stringsdict")
        XCTAssertNil(none, "the file type is part of the identity")
    }
}
