import Foundation
import os

/// The SDK's one logging call site. Debug level only: nothing reaches the default log of a release build.
enum Log {
    static func debug(_ message: @autoclosure () -> String) {}

    /// Receives every message as well; for tests.
    static func setSink(_ sink: (@Sendable (String) -> Void)?) {}
}
