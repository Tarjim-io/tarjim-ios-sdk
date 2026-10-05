import Foundation
import XCTest
@testable import Tarjim

final class StoreLayoutTests: XCTestCase {
    func testTheReleaseInstallsEveryWantedSlotByteForByte() async throws {
        let root = try StoreFixtures.root(for: self)
        let store = try StoreFixtures.store(root)
        try await StoreFixtures.stageRelease(store)
        let plan = try StoreFixtures.releasePlan()
        let install = try await store.makeInstall(plan)

        XCTAssertEqual(install.directory, "1-\(plan.checksum.prefix(8))")
        XCTAssertEqual(install.checksum, plan.checksum)
        XCTAssertEqual(install.releaseId, 42)
        XCTAssertEqual(install.owedSlots, [])

        let wanted = try StoreFixtures.allWanted()
        XCTAssertEqual(wanted.count, 16)
        var expected: Set<String> = ["manifest.json", "install.json"]
        for slot in wanted {
            expected.insert("\(slot.bundleId).bundle/Info.plist")
            expected.insert("\(slot.bundleId).bundle/\(slot.locale).lproj/Localizable.\(slot.fileType)")
        }
        let directory = store.url(of: install)
        XCTAssertEqual(directory, store.directory.appendingPathComponent("installs/\(install.directory)", isDirectory: true))
        XCTAssertEqual(try StoreFixtures.files(under: directory), expected)
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("manifest.json")), plan.manifestRaw)
        for slot in wanted {
            let url = try XCTUnwrap(store.fileURL(of: install, slot: slot), "\(slot)")
            XCTAssertEqual(url.path, directory.appendingPathComponent("\(slot.bundleId).bundle/\(slot.locale).lproj/Localizable.\(slot.fileType)").path)
            let hash = try XCTUnwrap(plan.listed[slot])
            XCTAssertEqual(try Data(contentsOf: url), try StoreFixtures.objectBytes(hash: hash, fileType: slot.fileType), "\(slot)")
        }
    }

    func testInfoPlistDeclaresABundleInTheBaseLocale() async throws {
        for (baseLocale, region) in [("ar", "ar"), (nil, "en")] as [(String?, String)] {
            let root = try StoreFixtures.root(for: self)
            let store = try StoreFixtures.store(root)
            try await StoreFixtures.stageRelease(store)
            let install = try await store.makeInstall(StoreFixtures.releasePlan(baseLocale: baseLocale))
            let data = try Data(contentsOf: store.url(of: install).appendingPathComponent("b3.bundle/Info.plist"))
            let plist = try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
            XCTAssertEqual(plist["CFBundlePackageType"] as? String, "BNDL")
            XCTAssertEqual(plist["CFBundleDevelopmentRegion"] as? String, region)
        }
    }

    /// The install holds exactly the wanted slots: no companion file, no bundle nobody asked for.
    func testOnlyWantedSlotsAreWritten() async throws {
        let root = try StoreFixtures.root(for: self)
        let store = try StoreFixtures.store(root)
        let wanted: Set<Slot> = [StoreFixtures.slot("ns7", "ar", "strings")]
        try await StoreFixtures.stageRelease(store, wanted: wanted)
        let install = try await store.makeInstall(StoreFixtures.releasePlan(wanted: wanted))
        XCTAssertEqual(try StoreFixtures.files(under: store.url(of: install)),
                       ["manifest.json", "install.json", "ns7.bundle/Info.plist", "ns7.bundle/ar.lproj/Localizable.strings"])
        XCTAssertNil(store.fileURL(of: install, slot: StoreFixtures.slot("ns7", "ar", "stringsdict")))
        XCTAssertNil(store.fileURL(of: install, slot: StoreFixtures.slot("ns12", "ar", "strings")))
    }

    /// Only Apple's two formats are installed; a slot the manifest does not list is nothing to owe.
    func testAnUnlistedSlotOrAnotherFileTypeIsIgnored() async throws {
        let root = try StoreFixtures.root(for: self)
        let store = try StoreFixtures.store(root)
        let real = StoreFixtures.slot("ns7", "en", "strings")
        let wanted: Set<Slot> = [real, StoreFixtures.slot("ns99", "en", "strings"), StoreFixtures.slot("ns7", "en", "json")]
        try await StoreFixtures.stageRelease(store, wanted: [real, StoreFixtures.slot("ns7", "en", "json")])
        let install = try await store.makeInstall(StoreFixtures.releasePlan(wanted: wanted))
        XCTAssertEqual(install.owedSlots, [])
        XCTAssertEqual(try StoreFixtures.files(under: store.url(of: install)),
                       ["manifest.json", "install.json", "ns7.bundle/Info.plist", "ns7.bundle/en.lproj/Localizable.strings"])
    }

    /// Names come from the server; none may climb out of the store.
    func testUnsafeNamesAreRefused() async throws {
        let root = try StoreFixtures.root(for: self)
        let store = try StoreFixtures.store(root)
        let data = Data("\"k\" = \"v\";".utf8)
        let hash = Fixtures.sha256Hex(data)
        let checksum = String(repeating: "a", count: 64)
        for (badChecksum, badHash, badType) in [("../../x", hash, "strings"), (checksum, "../\(hash)", "strings"),
                                                (checksum, hash, "strings/../../x"), (checksum, hash.uppercased(), "strings"),
                                                (checksum, hash, "")] {
            do {
                try await store.stage(checksum: badChecksum, hash: badHash, fileType: badType, verifiedBytes: data)
                XCTFail("staged \(badChecksum) \(badHash) \(badType)")
            } catch let error as StoreError {
                guard case .unsafeName = error else { return XCTFail("\(error)") }
            }
        }

        var plan = StoreFixtures.plan(checksum: "a", files: [StoreFixtures.slot(): data])
        plan = InstallPlan(checksum: "../../evil", releaseId: nil, baseLocale: nil, manifestRaw: plan.manifestRaw,
                           listed: plan.listed, wanted: plan.wanted)
        do {
            _ = try await store.makeInstall(plan)
            XCTFail("installed under an unsafe checksum")
        } catch let error as StoreError {
            guard case .unsafeName = error else { return XCTFail("\(error)") }
        }

        let good = StoreFixtures.slot("ns7", "en", "strings")
        let bad: [Slot] = [StoreFixtures.slot("../evil", "en", "strings"), StoreFixtures.slot("ns7", "../../en", "strings"),
                           StoreFixtures.slot("ns7/x", "en", "strings")]
        var files: [Slot: Data] = [good: data]
        for slot in bad { files[slot] = data }
        let unsafePlan = StoreFixtures.plan(checksum: "b", files: files)
        try await StoreFixtures.stage(store, unsafePlan, [good: data])
        let install = try await store.makeInstall(unsafePlan)
        XCTAssertEqual(install.owedSlots, [])
        XCTAssertEqual(try StoreFixtures.files(under: store.url(of: install)),
                       ["manifest.json", "install.json", "ns7.bundle/Info.plist", "ns7.bundle/en.lproj/Localizable.strings"])
        XCTAssertFalse(StoreFixtures.exists(store.directory.appendingPathComponent("installs/evil.bundle")))
        XCTAssertFalse(StoreFixtures.exists(root.appendingPathComponent("Tarjim/v1/evil.bundle")))
    }

    func testTheTarjimDirectoryIsCreatedAndExcludedFromBackup() throws {
        let root = try StoreFixtures.root(for: self)
        let store = try StoreFixtures.store(root)
        XCTAssertTrue(StoreFixtures.exists(store.directory))
        XCTAssertEqual(store.directory.path, root.appendingPathComponent("Tarjim/v1/\(StoreFixtures.identifier)").path)
        let values = try root.appendingPathComponent("Tarjim").resourceValues(forKeys: [.isExcludedFromBackupKey])
        XCTAssertEqual(values.isExcludedFromBackup, true)
    }
}
