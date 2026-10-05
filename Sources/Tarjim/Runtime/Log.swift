import Foundation
import os

/// A plain lock: the os-level unfair lock type needs iOS 16.
private final class SinkBox: @unchecked Sendable {
    private let lock = NSLock()
    private var sink: (@Sendable (String) -> Void)?

    var value: (@Sendable (String) -> Void)? {
        get { lock.withLock { sink } }
        set { lock.withLock { sink = newValue } }
    }
}

/// The SDK's one logging call site. Debug level only: nothing reaches the default log of a release build.
enum Log {
    private static let logger = Logger(subsystem: "io.tarjim.sdk", category: "sdk")
    private static let sink = SinkBox()

    /// Callers only pass reports and states, never the key, so the message is safe to show unredacted.
    static func debug(_ message: @autoclosure () -> String) {
        let text = message()
        logger.debug("\(text, privacy: .public)")
        sink.value?(text)
    }

    /// Receives every message as well; for tests.
    static func setSink(_ sink: (@Sendable (String) -> Void)?) {
        self.sink.value = sink
    }
}
