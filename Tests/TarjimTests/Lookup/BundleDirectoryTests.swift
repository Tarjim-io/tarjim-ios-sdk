import XCTest
@testable import Tarjim

final class BundleDirectoryTests: XCTestCase {
    func testABundleIsFoundByTypeAndName() {
        let entries = LookupFixtures.entries
        XCTAssertEqual(BundleDirectory.id(for: .namespace("default"), in: entries), "ns7")
        XCTAssertEqual(BundleDirectory.id(for: .namespace("checkout"), in: entries), "ns12")
        XCTAssertEqual(BundleDirectory.id(for: .custom("checkout-screen"), in: entries), "b3")
        XCTAssertNil(BundleDirectory.id(for: .custom("checkout"), in: entries))
        XCTAssertNil(BundleDirectory.id(for: .namespace("checkout-screen"), in: entries))
    }

    /// A custom bundle may share a namespace's name; neither lookup returns the other.
    func testACustomBundleIsNeverReturnedForANamespace() {
        let entries = [ManifestBundle(id: "b9", type: "custom", name: "default"), ManifestBundle(id: "ns7", type: "namespace", name: "default")]
        XCTAssertEqual(BundleDirectory.id(for: .namespace("default"), in: entries), "ns7")
        XCTAssertEqual(BundleDirectory.id(for: .custom("default"), in: entries), "b9")
    }

    /// Of two entries sharing type and name, the lowest NUMERIC id wins: `ns7` before `ns10`.
    func testTheLowestNumericIdWins() {
        let entries = [ManifestBundle(id: "ns10", type: "namespace", name: "x"), ManifestBundle(id: "ns7", type: "namespace", name: "x"),
                       ManifestBundle(id: "ns9", type: "namespace", name: "x")]
        XCTAssertEqual(BundleDirectory.id(for: .namespace("x"), in: entries), "ns7")
        let customs = [ManifestBundle(id: "b12", type: "custom", name: "y"), ManifestBundle(id: "b2", type: "custom", name: "y")]
        XCTAssertEqual(BundleDirectory.id(for: .custom("y"), in: customs), "b2")
    }

    func testAnUnknownTypeNeverMatches() {
        let entries = [ManifestBundle(id: "x1", type: "screen", name: "default"), ManifestBundle(id: "ns30", type: "namespace", name: "default")]
        XCTAssertEqual(BundleDirectory.id(for: .namespace("default"), in: entries), "ns30")
        XCTAssertNil(BundleDirectory.id(for: .custom("default"), in: entries))
    }
}
