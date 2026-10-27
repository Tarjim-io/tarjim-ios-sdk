import Foundation
import XCTest
@testable import Tarjim

/// What the SDK declares to Apple must match what it does: no tracking, one optional identifier, no required-reason API.
final class PrivacyManifestTests: XCTestCase {
    private func manifest() throws -> [String: Any] {
        let url = try XCTUnwrap(PrivacyManifest.url, "PrivacyInfo.xcprivacy ships with the SDK")
        return try XCTUnwrap(PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil) as? [String: Any])
    }

    func testNothingIsTracked() throws {
        let manifest = try manifest()
        XCTAssertEqual(manifest["NSPrivacyTracking"] as? Bool, false)
        XCTAssertEqual((manifest["NSPrivacyTrackingDomains"] as? [String]) ?? [], [])
    }

    /// The per-install identifier (off by default; `sendsInstallIdentifier = true` sends it) is the only data collected:
    /// not linked to the user, not used for tracking, used to count active installs.
    func testTheInstallIdentifierIsTheOnlyCollectedData() throws {
        let collected = try XCTUnwrap(try manifest()["NSPrivacyCollectedDataTypes"] as? [[String: Any]])
        XCTAssertEqual(collected.count, 1)
        let identifier = try XCTUnwrap(collected.first)
        XCTAssertEqual(identifier["NSPrivacyCollectedDataType"] as? String, "NSPrivacyCollectedDataTypeDeviceID")
        XCTAssertEqual(identifier["NSPrivacyCollectedDataTypeLinked"] as? Bool, false)
        XCTAssertEqual(identifier["NSPrivacyCollectedDataTypeTracking"] as? Bool, false)
        XCTAssertEqual(identifier["NSPrivacyCollectedDataTypePurposes"] as? [String], ["NSPrivacyCollectedDataTypePurposeAnalytics"])
    }

    /// No required-reason API is declared, so none may be used.
    func testNoRequiredReasonAPIIsUsed() throws {
        XCTAssertEqual(((try manifest()["NSPrivacyAccessedAPITypes"] as? [Any]) ?? [0]).count, 0)
        let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/Tarjim")
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
        var offenders: [String] = []
        var scanned = 0
        let apis = ["UserDefaults", "systemUptime", "mach_absolute_time", "mach_continuous_time", "creationDate", "modificationDate", "contentModificationDate",
                    "volumeAvailableCapacity", "systemFreeSize", "systemSize", "activeInputModes", "statfs", "fstat(", "stat(", "getattrlist"]
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            scanned += 1
            let text = try String(contentsOf: url, encoding: .utf8)
            for api in apis where text.contains(api) { offenders.append("\(url.lastPathComponent): \(api)") }
        }
        XCTAssertGreaterThan(scanned, 10)
        XCTAssertEqual(offenders, [])
    }
}
