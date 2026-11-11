import Foundation
import XCTest
@testable import Tarjim

/// What the SDK declares to Apple must match what it does: no tracking, what an update check sends, no required-reason API.
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

    /// What an update check sends is declared, neither linked to the user nor used for tracking: the per-install
    /// identifier (on by default; `sendsInstallIdentifier = false` sends none) to count active installs, and the app
    /// and device details in the query (app version, iOS version, build number, language), which pick the release
    /// and are counted.
    func testWhatAnUpdateCheckSendsIsDeclared() throws {
        let collected = try XCTUnwrap(try manifest()["NSPrivacyCollectedDataTypes"] as? [[String: Any]])
        let byType = Dictionary(uniqueKeysWithValues: collected.compactMap { entry in
            (entry["NSPrivacyCollectedDataType"] as? String).map { ($0, entry) }
        })
        XCTAssertEqual(Set(byType.keys), ["NSPrivacyCollectedDataTypeDeviceID", "NSPrivacyCollectedDataTypeOtherDiagnosticData"])
        XCTAssertEqual(collected.count, 2)
        for entry in collected {
            XCTAssertEqual(entry["NSPrivacyCollectedDataTypeLinked"] as? Bool, false)
            XCTAssertEqual(entry["NSPrivacyCollectedDataTypeTracking"] as? Bool, false)
        }
        XCTAssertEqual(byType["NSPrivacyCollectedDataTypeDeviceID"]?["NSPrivacyCollectedDataTypePurposes"] as? [String],
                       ["NSPrivacyCollectedDataTypePurposeAnalytics"])
        XCTAssertEqual(Set(byType["NSPrivacyCollectedDataTypeOtherDiagnosticData"]?["NSPrivacyCollectedDataTypePurposes"] as? [String] ?? []),
                       ["NSPrivacyCollectedDataTypePurposeAppFunctionality", "NSPrivacyCollectedDataTypePurposeAnalytics"])
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
