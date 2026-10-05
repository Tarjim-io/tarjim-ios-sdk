import Foundation
import XCTest
@testable import Tarjim

/// The release-1 fixture as an install plan, plus a throwaway root per test.
enum StoreFixtures {
    static let identifier = "0123456789abcdef0123456789abcdef"
    static let sdkVersion = "0.1.0"

    static func root(for test: XCTestCase) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("tarjim-store-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        test.addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    static func store(_ root: URL, identifier: String = identifier, sdkVersion: String = sdkVersion) throws -> Store {
        try Store(root: root, identifier: identifier, sdkVersion: sdkVersion)
    }

    static func manifestRaw() throws -> Data {
        try Fixtures.data("release-1/manifest.json")
    }

    static func checksum() throws -> String {
        Fixtures.sha256Hex(try manifestRaw())
    }

    /// Every slot the release-1 manifest lists, every file type included.
    static func listed() throws -> [Slot: String] {
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: manifestRaw()) as? [String: Any])
        let slices = try XCTUnwrap(object["slices"] as? [String: [String: [String: [String: Any]]]])
        var out: [Slot: String] = [:]
        for (bundleId, byLocale) in slices {
            for (locale, byType) in byLocale {
                for (fileType, entry) in byType {
                    out[Slot(bundleId: bundleId, locale: locale, fileType: fileType)] = try XCTUnwrap(entry["hash"] as? String)
                }
            }
        }
        return out
    }

    /// The slots an app with both locales selected wants: strings and stringsdict of every bundle.
    static func allWanted() throws -> Set<Slot> {
        Set(try listed().keys.filter { $0.fileType == "strings" || $0.fileType == "stringsdict" })
    }

    static func releasePlan(wanted: Set<Slot>? = nil, baseLocale: String? = "en") throws -> InstallPlan {
        InstallPlan(checksum: try checksum(), releaseId: 42, baseLocale: baseLocale, manifestRaw: try manifestRaw(),
                    listed: try listed(), wanted: try wanted ?? allWanted())
    }

    static func objectBytes(hash: String, fileType: String) throws -> Data {
        try Fixtures.data("release-1/objects/\(hash).\(fileType)")
    }

    /// Stages every object the release-1 plan wants.
    static func stageRelease(_ store: Store, wanted: Set<Slot>? = nil) async throws {
        let listed = try listed()
        let checksum = try checksum()
        for slot in try wanted ?? allWanted() {
            let hash = try XCTUnwrap(listed[slot])
            try await store.stage(checksum: checksum, hash: hash, fileType: slot.fileType,
                                  verifiedBytes: objectBytes(hash: hash, fileType: slot.fileType))
        }
    }

    /// A made-up release: `checksum` repeated hex, slots whose bytes are given here.
    static func plan(checksum: Character, releaseId: Int? = nil, files: [Slot: Data], extraListed: [Slot: String] = [:],
                     wanted: Set<Slot>? = nil) -> InstallPlan {
        var listed = extraListed
        for (slot, data) in files { listed[slot] = Fixtures.sha256Hex(data) }
        return InstallPlan(checksum: String(repeating: checksum, count: 64), releaseId: releaseId, baseLocale: "en",
                           manifestRaw: Data("{\"release\":\"\(checksum)\"}".utf8), listed: listed,
                           wanted: wanted ?? Set(listed.keys))
    }

    static func stage(_ store: Store, _ plan: InstallPlan, _ files: [Slot: Data]) async throws {
        for (slot, data) in files {
            try await store.stage(checksum: plan.checksum, hash: Fixtures.sha256Hex(data), fileType: slot.fileType, verifiedBytes: data)
        }
    }

    static func slot(_ bundleId: String = "ns7", _ locale: String = "ar", _ fileType: String = "strings") -> Slot {
        Slot(bundleId: bundleId, locale: locale, fileType: fileType)
    }

    /// Regular files under `directory`, relative to it.
    static func files(under directory: URL) throws -> Set<String> {
        let base = directory.resolvingSymlinksInPath().path
        guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey]) else { return [] }
        var out = Set<String>()
        for case let url as URL in enumerator where (try url.resourceValues(forKeys: [.isRegularFileKey])).isRegularFile == true {
            out.insert(String(url.resolvingSymlinksInPath().path.dropFirst(base.count + 1)))
        }
        return out
    }

    static func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }
}
