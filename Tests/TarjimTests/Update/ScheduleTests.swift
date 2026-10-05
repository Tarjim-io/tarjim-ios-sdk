import XCTest
@testable import Tarjim

final class ScheduleTests: XCTestCase {
    func testTheLaunchDelayIsZeroToThirtySeconds() {
        XCTAssertEqual(Schedule.launchDelay(random: 0), 0)
        XCTAssertEqual(Schedule.launchDelay(random: 0.5), 15, accuracy: 0.001)
        XCTAssertLessThanOrEqual(Schedule.launchDelay(random: 0.999_999), 30)
    }

    /// `pollAfter` is a minimum: jitter only ever adds, up to 20 %.
    func testThePollDelayIsPollAfterPlusUpToTwentyPercent() {
        XCTAssertEqual(Schedule.pollDelay(pollAfter: 1800, random: 0), 1800)
        XCTAssertEqual(Schedule.pollDelay(pollAfter: 1800, random: 0.5), 1980, accuracy: 0.001)
        XCTAssertLessThanOrEqual(Schedule.pollDelay(pollAfter: 1800, random: 0.999_999), 2160)
    }

    func testBackoffDoublesFromSixtySecondsUpToPollAfter() {
        XCTAssertEqual(Schedule.backoff(step: 1, pollAfter: 1800, retryAfter: nil), 60)
        XCTAssertEqual(Schedule.backoff(step: 2, pollAfter: 1800, retryAfter: nil), 120)
        XCTAssertEqual(Schedule.backoff(step: 5, pollAfter: 1800, retryAfter: nil), 960)
        XCTAssertEqual(Schedule.backoff(step: 6, pollAfter: 1800, retryAfter: nil), 1800)
        XCTAssertEqual(Schedule.backoff(step: 500, pollAfter: 1800, retryAfter: nil), 1800, "no overflow at any step")
        XCTAssertEqual(Schedule.backoff(step: 1, pollAfter: 30, retryAfter: nil), 30)
    }

    /// A throttled fleet must actually slow down: `Retry-After` wins, even past `pollAfter`.
    func testRetryAfterIsAFloorEvenBeyondPollAfter() {
        XCTAssertEqual(Schedule.backoff(step: 1, pollAfter: 1800, retryAfter: 300), 300)
        XCTAssertEqual(Schedule.backoff(step: 6, pollAfter: 1800, retryAfter: 7200), 7200)
        XCTAssertEqual(Schedule.backoff(step: 3, pollAfter: 1800, retryAfter: 10), 240)
    }
}
