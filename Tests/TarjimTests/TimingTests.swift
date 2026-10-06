import XCTest

final class TimingTests: XCTestCase {
    func testBoundsApplyByDefault() {
        XCTAssertTrue(Timing.boundsApply([:]))
    }

    func testBoundsAreSkippedWhenAsked() {
        XCTAssertFalse(Timing.boundsApply(["TARJIM_NO_TIMING": "1"]))
    }
}
