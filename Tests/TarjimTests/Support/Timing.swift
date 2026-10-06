import Foundation
import XCTest

/// Wall-clock bounds for the tests that guard against a slow algorithm.
enum Timing {
    /// False when `TARJIM_NO_TIMING` is set. CI sets it on the simulator jobs, whose shared machines vary too much
    /// for a fixed bound; the macOS host jobs still check every bound.
    static func boundsApply(_ environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        environment["TARJIM_NO_TIMING"] == nil
    }

    static func assertElapsed(since started: Date, under limit: TimeInterval,
                              file: StaticString = #filePath, line: UInt = #line) {
        guard boundsApply() else { return }
        XCTAssertLessThan(Date().timeIntervalSince(started), limit, file: file, line: line)
    }
}
