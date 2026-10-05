import Foundation

/// When to read `meta`. Every input that varies (randomness, `Retry-After`) is passed in.
enum Schedule {
    /// The 0…30 s delay before the first check of a launch; `random` is in 0..<1.
    static func launchDelay(random: Double) -> TimeInterval {
        30 * random
    }

    /// The timer for the next check: `pollAfter` plus 0…20 % jitter, never less than `pollAfter`.
    static func pollDelay(pollAfter: Int, random: Double) -> TimeInterval {
        TimeInterval(pollAfter) * (1 + 0.2 * random)
    }

    /// The wait after the `step`-th consecutive failure (step ≥ 1): from 60 s doubling up to `pollAfter`, and
    /// never less than `Retry-After`, even beyond `pollAfter`.
    static func backoff(step: Int, pollAfter: Int, retryAfter: Int?) -> TimeInterval {
        // 60 · 2^30 is far past any pollAfter; a larger exponent could overflow Int.
        let exponent = min(max(step - 1, 0), 30)
        let doubled = min(60 << exponent, pollAfter)
        return TimeInterval(max(doubled, retryAfter ?? 0))
    }
}
