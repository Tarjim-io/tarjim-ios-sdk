import Foundation
import os

/// The SDK's one logging call site. Debug level only: nothing reaches the default log of a release build.
enum Log {
    private static let logger = Logger(subsystem: "io.tarjim.sdk", category: "sdk")
    private static let sink = OSAllocatedUnfairLock<(@Sendable (String) -> Void)?>(initialState: nil)

    /// Callers only pass reports and states, never the key, so the message is safe to show unredacted.
    static func debug(_ message: @autoclosure () -> String) {
        let text = message()
        logger.debug("\(text, privacy: .public)")
        sink.withLock { $0 }?(text)
    }

    /// Receives every message as well; for tests.
    static func setSink(_ sink: (@Sendable (String) -> Void)?) {
        self.sink.withLock { $0 = sink }
    }
}
