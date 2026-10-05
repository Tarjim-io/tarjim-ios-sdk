import Foundation
import XCTest
@testable import Tarjim

/// What must hold after crashes, background cleanups and later SDK versions.
final class StoreRecoveryTests: XCTestCase {
    private let one = Data("\"k\" = \"one\";".utf8)
    private let two = Data("\"k\" = \"two\";".utf8)
    private let three = Data("\"k\" = \"three\";".utf8)
    private let slot = StoreFixtures.slot()

    private func installed(_ store: Store, _ checksum: Character, _ files: [Slot: Data]) async throws -> InstallRecord {
        let plan = StoreFixtures.plan(checksum: checksum, files: files)
        try await StoreFixtures.stage(store, plan, files)
        return try await store.makeInstall(plan)
    }

    /// The cleanup after `start()` may run between building an install and recording it — also while ANOTHER
    /// install is recorded in between.
    func testANewInstallSurvivesACleanupBeforeItIsRecorded() async throws {
        let root = try StoreFixtures.root(for: self)
        let store = try StoreFixtures.store(root)
        let install = try await installed(store, "a", [slot: one])
        let other = try await installed(store, "b", [slot: two])
        try await store.activate(other)
        _ = try await store.cleanup()
        XCTAssertTrue(StoreFixtures.exists(store.url(of: install)))
        try await store.setPending(install)
        XCTAssertNotNil(store.fileURL(of: install, slot: slot))
    }

    /// state.json must always name a complete directory.
    func testRecordingAnInstallThatIsNotOnDiskIsRefused() async throws {
        let root = try StoreFixtures.root(for: self)
        let store = try StoreFixtures.store(root)
        let ghost = InstallRecord(directory: "9-deadbeef", checksum: String(repeating: "d", count: 64), releaseId: nil, owedSlots: [])
        for record in [{ try await store.activate(ghost) }, { try await store.setPending(ghost) }] as [() async throws -> Void] {
            do {
                try await record()
                XCTFail("recorded a missing install")
            } catch let error as StoreError {
                XCTAssertEqual(error, .missingInstall("9-deadbeef"))
            }
        }
        let state = await store.state
        XCTAssertNil(state.active)
        XCTAssertNil(state.pending)
        try await store.setPending(nil)
    }

    /// A second install of the same checksum (a language change) keeps the last OTHER release as previous, so a
    /// launch-crash revert of that checksum lands on a release that did not crash.
    func testPreviousIsTheLastInstallOfAnotherChecksum() async throws {
        let root = try StoreFixtures.root(for: self)
        let store = try StoreFixtures.store(root)
        let r1 = try await installed(store, "a", [slot: one])
        try await store.activate(r1)
        let r2 = try await installed(store, "b", [slot: two])
        try await store.activate(r2)
        let r2again = try await installed(store, "b", [slot: two, StoreFixtures.slot("ns7", "en", "strings"): three])
        try await store.activate(r2again)
        let state = await store.state
        XCTAssertEqual(state.active, r2again)
        XCTAssertEqual(state.previous, r1)
    }

    func testStagingOfABadChecksumIsNotASource() async throws {
        let root = try StoreFixtures.root(for: self)
        let store = try StoreFixtures.store(root)
        let bad = StoreFixtures.plan(checksum: "a", files: [slot: one])
        try await StoreFixtures.stage(store, bad, [slot: one])
        var state = await store.state
        state.badChecksums = [bad.checksum]
        try await store.save(state)
        let held = await store.heldObject(hash: Fixtures.sha256Hex(one), fileType: "strings")
        XCTAssertNil(held)
        let install = try await store.makeInstall(StoreFixtures.plan(checksum: "b", files: [slot: one]))
        XCTAssertEqual(install.owedSlots, [slot])
    }

    /// A crash between writing and renaming leaves a temporary file behind; nothing ever reads it.
    func testCleanupRemovesTemporaryFilesACrashLeftBehind() async throws {
        let root = try StoreFixtures.root(for: self)
        let store = try StoreFixtures.store(root)
        let plan = StoreFixtures.plan(checksum: "a", files: [slot: one])
        try await StoreFixtures.stage(store, plan, [slot: one])
        try Data("{".utf8).write(to: store.directory.appendingPathComponent(".state-crashed.tmp"))
        try Data("x".utf8).write(to: store.directory.appendingPathComponent("staging/\(plan.checksum)/.crashed.tmp"))
        let removed = try await store.cleanup()
        let id = StoreFixtures.identifier
        XCTAssertEqual(Set(removed), ["v1/\(id)/.state-crashed.tmp", "v1/\(id)/staging/\(plan.checksum)/.crashed.tmp"])
        let staged = await store.stagedObjects(checksum: plan.checksum)
        XCTAssertEqual(staged, ["\(Fixtures.sha256Hex(one)).strings"])
    }

    /// A file can be cut short on disk (a power loss before the data reached it); its name is then a lie.
    func testAFileWhoseBytesNoLongerMatchItsHashIsNotInstalled() async throws {
        let root = try StoreFixtures.root(for: self)
        let store = try StoreFixtures.store(root)
        let plan = StoreFixtures.plan(checksum: "a", files: [slot: one])
        let staging = store.directory.appendingPathComponent("staging/\(plan.checksum)", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        try one.prefix(3).write(to: staging.appendingPathComponent("\(Fixtures.sha256Hex(one)).strings"))
        let install = try await store.makeInstall(plan)
        XCTAssertEqual(install.owedSlots, [slot])
        XCTAssertNil(store.fileURL(of: install, slot: slot))
    }

    func testAnInstalledFileCutShortIsNotReused() async throws {
        let root = try StoreFixtures.root(for: self)
        let store = try StoreFixtures.store(root)
        let first = try await installed(store, "a", [slot: one])
        try await store.activate(first)
        var state = await store.state
        state.stagingChecksum = nil
        try await store.save(state)
        _ = try await store.cleanup()
        try one.prefix(3).write(to: XCTUnwrap(store.fileURL(of: first, slot: slot)))
        let install = try await store.makeInstall(StoreFixtures.plan(checksum: "b", files: [slot: one]))
        XCTAssertEqual(install.owedSlots, [slot])
        XCTAssertNil(store.fileURL(of: install, slot: slot), "neither as a reused file nor as the active install's file")
    }

    /// `<n>` only ever increases: a counter lost to a crash or an unreadable state.json resumes above what is on disk.
    func testTheNumberResumesAboveEveryInstallOnDisk() async throws {
        let root = try StoreFixtures.root(for: self)
        let store = try StoreFixtures.store(root)
        try FileManager.default.createDirectory(at: store.directory.appendingPathComponent("installs/7-bbbbbbbb", isDirectory: true),
                                                withIntermediateDirectories: true)
        let install = try await installed(store, "a", [slot: one])
        XCTAssertEqual(install.directory, "8-aaaaaaaa")
    }

    /// A later SDK adds fields to state.json and an earlier one may drop some; neither may cost the device its installs.
    func testAStateWithMissingOrExtraFieldsKeepsWhatItHas() async throws {
        let root = try StoreFixtures.root(for: self)
        let store = try StoreFixtures.store(root)
        let install = try await installed(store, "a", [slot: one])
        try await store.activate(install)
        let file = store.directory.appendingPathComponent("state.json")
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        for key in ["launchCrashCount", "deliveredReports", "rejectedChecksums", "badChecksums", "backoffStep", "nextInstallNumber"] {
            XCTAssertNotNil(object.removeValue(forKey: key), key)
        }
        object["addedByALaterVersion"] = ["x": 1]
        try JSONSerialization.data(withJSONObject: object).write(to: file)
        let reread = try await StoreFixtures.store(root).state
        XCTAssertEqual(reread.active, install)
        XCTAssertEqual(reread.launchCrashCount, 0)
        XCTAssertEqual(reread.badChecksums, [])
    }

    /// Replaced, never rewritten in place: a reader (or a crash) sees the old file or the new one.
    func testSaveReplacesTheFileRatherThanRewritingIt() async throws {
        let root = try StoreFixtures.root(for: self)
        let store = try StoreFixtures.store(root)
        var state = StoreState(sdkVersion: StoreFixtures.sdkVersion)
        try await store.save(state)
        let file = store.directory.appendingPathComponent("state.json")
        let before = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: file.path)[.systemFileNumber] as? Int)
        state.backoffStep = 3
        try await store.save(state)
        let after = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: file.path)[.systemFileNumber] as? Int)
        XCTAssertNotEqual(before, after)
    }

    /// The install holds what its manifest lists: a slot the new release dropped is not carried over.
    func testASlotTheNewManifestDropsIsNotCarriedOver() async throws {
        let root = try StoreFixtures.root(for: self)
        let store = try StoreFixtures.store(root)
        let dropped = StoreFixtures.slot("ns7", "en", "strings")
        let first = try await installed(store, "a", [slot: one, dropped: two])
        try await store.activate(first)
        let next = StoreFixtures.plan(checksum: "b", files: [slot: one], wanted: [slot, dropped])
        let install = try await store.makeInstall(next)
        XCTAssertEqual(install.owedSlots, [])
        XCTAssertNil(store.fileURL(of: install, slot: dropped))
    }

    /// An owed slot keeps what the user sees now: the ACTIVE install's file, not a pending or previous one.
    func testAnOwedSlotTakesTheActiveInstallsFileNotAnother() async throws {
        let root = try StoreFixtures.root(for: self)
        let store = try StoreFixtures.store(root)
        let older = try await installed(store, "a", [slot: one])
        try await store.activate(older)
        let active = try await installed(store, "b", [slot: two])
        try await store.activate(active)
        let pending = try await installed(store, "c", [slot: three])
        try await store.setPending(pending)
        let install = try await store.makeInstall(StoreFixtures.plan(checksum: "d", files: [slot: Data("unheld".utf8)]))
        XCTAssertEqual(install.owedSlots, [slot])
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(store.fileURL(of: install, slot: slot))), two)
    }

    /// When a release lists only the plural file for a slot, no empty `.strings` companion appears.
    func testOnlyTheListedFileTypeIsWritten() async throws {
        let root = try StoreFixtures.root(for: self)
        let store = try StoreFixtures.store(root)
        let plural = StoreFixtures.slot("ns7", "ar", "stringsdict")
        let data = Data("<plist/>".utf8)
        let plan = StoreFixtures.plan(checksum: "a", files: [plural: data], wanted: [plural, slot])
        try await StoreFixtures.stage(store, plan, [plural: data])
        let install = try await store.makeInstall(plan)
        XCTAssertEqual(install.owedSlots, [])
        XCTAssertEqual(try StoreFixtures.files(under: store.url(of: install)),
                       ["manifest.json", "install.json", "ns7.bundle/Info.plist", "ns7.bundle/ar.lproj/Localizable.stringsdict"])
    }

    /// A crash mid-build leaves `build-<n>` behind; a retry with the same number must start from nothing.
    func testALeftoverBuildDirectoryDoesNotLeakIntoTheNextInstall() async throws {
        let root = try StoreFixtures.root(for: self)
        let plan = StoreFixtures.plan(checksum: "a", files: [slot: one])
        let leftover = try StoreFixtures.store(root).directory.appendingPathComponent("staging/\(plan.checksum)/build-1", isDirectory: true)
        try FileManager.default.createDirectory(at: leftover.appendingPathComponent("ns7.bundle/fr.lproj"), withIntermediateDirectories: true)
        try Data("\"x\" = \"y".utf8).write(to: leftover.appendingPathComponent("ns7.bundle/fr.lproj/Localizable.strings"))
        let stale: [String: Any] = ["CFBundlePackageType": "BNDL", "CFBundleDevelopmentRegion": "fr"]
        try PropertyListSerialization.data(fromPropertyList: stale, format: .xml, options: 0)
            .write(to: leftover.appendingPathComponent("ns7.bundle/Info.plist"))

        let store = try StoreFixtures.store(root, identifier: StoreFixtures.identifier)
        try await StoreFixtures.stage(store, plan, [slot: one])
        let install = try await store.makeInstall(plan)
        XCTAssertEqual(try StoreFixtures.files(under: store.url(of: install)),
                       ["manifest.json", "install.json", "ns7.bundle/Info.plist", "ns7.bundle/ar.lproj/Localizable.strings"])
        let info = try Data(contentsOf: store.url(of: install).appendingPathComponent("ns7.bundle/Info.plist"))
        let plist = try XCTUnwrap(PropertyListSerialization.propertyList(from: info, format: nil) as? [String: Any])
        XCTAssertEqual(plist["CFBundleDevelopmentRegion"] as? String, "en")
    }

    /// Simulators and Macs use case-insensitive volumes: `EN` and `en` are one directory there. Whatever survives,
    /// every installed file must be the bytes its manifest names.
    func testSlotsDifferingOnlyInCaseNeverInstallTheWrongBytes() async throws {
        let root = try StoreFixtures.root(for: self)
        let store = try StoreFixtures.store(root)
        let lower = StoreFixtures.slot("ns7", "en", "strings")
        let upper = StoreFixtures.slot("ns7", "EN", "strings")
        let plan = StoreFixtures.plan(checksum: "a", files: [lower: one, upper: two])
        try await StoreFixtures.stage(store, plan, [lower: one, upper: two])
        let install = try await store.makeInstall(plan)
        var served = 0
        for slot in [lower, upper] {
            guard let url = store.fileURL(of: install, slot: slot) else { continue }
            served += 1
            XCTAssertEqual(Fixtures.sha256Hex(try Data(contentsOf: url)), plan.listed[slot], "\(slot)")
        }
        XCTAssertGreaterThan(served, 0)
    }

    /// state.json is data from disk: names in it are checked like names from the server.
    func testUnsafeNamesInStateAreDroppedWhenItIsRead() async throws {
        let root = try StoreFixtures.root(for: self)
        let store = try StoreFixtures.store(root)
        let outside = root.appendingPathComponent("outside/build-9", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data("secret".utf8).write(to: root.appendingPathComponent("outside/secret.strings"))
        var state = StoreState(sdkVersion: StoreFixtures.sdkVersion)
        state.stagingChecksum = "../../../../outside"
        state.active = InstallRecord(directory: "../../../../outside", checksum: String(repeating: "a", count: 64), releaseId: nil, owedSlots: [])
        state.previous = InstallRecord(directory: "1-aaaaaaaa", checksum: "../x", releaseId: nil, owedSlots: [])
        state.pending = InstallRecord(directory: "2-bbbbbbbb", checksum: String(repeating: "c", count: 64), releaseId: nil, owedSlots: [])
        try await store.save(state)

        let reread = try StoreFixtures.store(root)
        let loaded = await reread.state
        XCTAssertNil(loaded.stagingChecksum)
        XCTAssertNil(loaded.active)
        XCTAssertNil(loaded.previous)
        XCTAssertNil(loaded.pending, "a directory whose name does not match its checksum")
        _ = try await reread.cleanup()
        XCTAssertTrue(StoreFixtures.exists(outside))
        let install = try await reread.makeInstall(StoreFixtures.plan(checksum: "d", files: [slot: one]))
        XCTAssertNil(reread.fileURL(of: install, slot: slot))
    }

    /// A corrupt counter must never crash the app that reads it.
    func testAnOutOfRangeCounterNeverTraps() async throws {
        for counter in [Int.max, -5, 0] {
            let root = try StoreFixtures.root(for: self)
            let store = try StoreFixtures.store(root)
            var state = StoreState(sdkVersion: StoreFixtures.sdkVersion)
            state.nextInstallNumber = counter
            try await store.save(state)
            let reread = try StoreFixtures.store(root)
            let install = try await installed(reread, "a", [slot: one])
            let number = try XCTUnwrap(Int(install.directory.split(separator: "-")[0]), install.directory)
            XCTAssertGreaterThanOrEqual(number, 1, "\(counter)")
        }
    }

    /// The path a process handed out stays retired even after cleanup removed it and state.json went back.
    func testARemovedPathIsNotReusedAfterStateGoesBack() async throws {
        let root = try StoreFixtures.root(for: self)
        let store = try StoreFixtures.store(root)
        let first = try await installed(store, "a", [slot: one])
        let second = try await installed(store, "b", [slot: two])
        try await store.activate(second)
        let relaunched = try StoreFixtures.store(root)
        _ = try await relaunched.cleanup()
        XCTAssertFalse(StoreFixtures.exists(store.url(of: first)))
        var rolledBack = await relaunched.state
        rolledBack.nextInstallNumber = 1
        try await relaunched.save(rolledBack)
        let third = try await installed(relaunched, "a", [slot: one])
        XCTAssertNotEqual(third.directory, first.directory)
    }

    /// A release of a few hundred slots builds in well under a second; the bound is loose for slow CI machines.
    func testBuildingALargeInstallStaysLinear() async throws {
        let root = try StoreFixtures.root(for: self)
        let store = try StoreFixtures.store(root)
        var files: [Slot: Data] = [:]
        for bundle in 0..<45 {
            for locale in 0..<10 {
                files[StoreFixtures.slot("ns\(bundle)", "l\(locale)", "strings")] = Data("\"k\" = \"\(bundle)-\(locale)\";".utf8)
            }
        }
        let plan = StoreFixtures.plan(checksum: "a", files: files)
        try await StoreFixtures.stage(store, plan, files)
        let started = Date()
        let install = try await store.makeInstall(plan)
        XCTAssertLessThan(Date().timeIntervalSince(started), 3)
        XCTAssertEqual(install.owedSlots, [])
    }

    /// What `heldObject` calls held must be what `makeInstall` would install, or the cycle never fetches it again.
    func testADamagedStagedFileIsNotHeld() async throws {
        let root = try StoreFixtures.root(for: self)
        let store = try StoreFixtures.store(root)
        let plan = StoreFixtures.plan(checksum: "a", files: [slot: one])
        try await StoreFixtures.stage(store, plan, [slot: one])
        let staged = store.directory.appendingPathComponent("staging/\(plan.checksum)/\(Fixtures.sha256Hex(one)).strings")
        try one.prefix(3).write(to: staged)
        let held = await store.heldObject(hash: Fixtures.sha256Hex(one), fileType: "strings")
        XCTAssertNil(held)
        try await store.stage(checksum: plan.checksum, hash: Fixtures.sha256Hex(one), fileType: "strings", verifiedBytes: one)
        let install = try await store.makeInstall(plan)
        XCTAssertEqual(install.owedSlots, [], "a fresh stage replaces the damaged file")
    }

    /// Only a written file claims its path: a slot with nothing to write must not push out one that has bytes.
    func testACaseTwinWithoutBytesDoesNotDisplaceOneWithBytes() async throws {
        let root = try StoreFixtures.root(for: self)
        let store = try StoreFixtures.store(root)
        let lower = StoreFixtures.slot("ns7", "en", "strings")
        let upper = StoreFixtures.slot("ns7", "EN", "strings")
        let plan = StoreFixtures.plan(checksum: "a", files: [lower: one, upper: two])
        try await StoreFixtures.stage(store, plan, [lower: one])
        let install = try await store.makeInstall(plan)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(store.fileURL(of: install, slot: lower))), one)
        XCTAssertFalse(install.owedSlots.contains(lower))
    }

    /// The cycle asks about every wanted object; the answer must not rescan the store each time.
    func testHeldObjectIsCheapWithManyInstalls() async throws {
        let root = try StoreFixtures.root(for: self)
        let store = try StoreFixtures.store(root)
        var files: [Slot: Data] = [:]
        for index in 0..<200 { files[StoreFixtures.slot("ns\(index)", "en", "strings")] = Data("\"k\" = \"\(index)\";".utf8) }
        for checksum: Character in ["a", "b", "c", "d", "e"] {
            let plan = StoreFixtures.plan(checksum: checksum, files: files)
            try await StoreFixtures.stage(store, plan, files)
            try await store.activate(try await store.makeInstall(plan))
        }
        let hashes = files.values.map { Fixtures.sha256Hex($0) }
        let started = Date()
        for round in 0..<5 {
            for hash in hashes {
                let held = await store.heldObject(hash: hash, fileType: "strings")
                XCTAssertNotNil(held, "\(round)")
            }
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 1.0)
    }

    /// `save` applies the same checks as loading: an unsafe name never reaches cleanup or a copy.
    func testSaveDropsUnsafeNamesToo() async throws {
        let root = try StoreFixtures.root(for: self)
        let store = try StoreFixtures.store(root)
        let outside = root.appendingPathComponent("outside/build-9", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        var state = StoreState(sdkVersion: StoreFixtures.sdkVersion)
        state.stagingChecksum = "../../../../outside"
        state.active = InstallRecord(directory: "../../../../outside", checksum: String(repeating: "a", count: 64), releaseId: nil, owedSlots: [])
        try await store.save(state)
        let saved = await store.state
        XCTAssertNil(saved.stagingChecksum)
        XCTAssertNil(saved.active)
        _ = try await store.cleanup()
        XCTAssertTrue(StoreFixtures.exists(outside))
    }
}
