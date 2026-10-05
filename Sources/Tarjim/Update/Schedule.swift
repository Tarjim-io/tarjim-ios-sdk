import Foundation

/// When to read `meta`. Every input that varies (randomness, `Retry-After`) is passed in.
enum Schedule {
    /// The 0…30 s delay before the first check of a launch (C3); `random` is in 0..<1.
    static func launchDelay(random: Double) -> TimeInterval {
        0
    }

    /// The timer for the next check: `pollAfter` plus 0…20 % jitter, never less than `pollAfter` (C3).
    static func pollDelay(pollAfter: Int, random: Double) -> TimeInterval {
        0
    }

    /// The wait after the `step`-th consecutive failure (step ≥ 1): from 60 s doubling up to `pollAfter` (C4), and
    /// never less than `Retry-After`, even beyond `pollAfter`.
    static func backoff(step: Int, pollAfter: Int, retryAfter: Int?) -> TimeInterval {
        0
    }
}
