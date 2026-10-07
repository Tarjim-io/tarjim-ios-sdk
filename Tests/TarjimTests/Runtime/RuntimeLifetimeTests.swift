import Foundation
import XCTest
@testable import Tarjim

/// A runtime nobody holds any more ends, started or not: nothing it hands out keeps it alive.
final class RuntimeLifetimeTests: XCTestCase {
    func testAStartedRuntimeIsFreedOnceReleased() async throws {
        let harness = try RuntimeHarness(self)
        harness.server.publish(try Release.one())
        weak var released: Runtime?
        do {
            let runtime = try harness.make()
            await runtime.start(foreground: true)
            await runtime.checkNow()
            await runtime.becameActive()
            await runtime.resignedActive()
            released = runtime
        }
        await EngineFixtures.settle(until: { released == nil })
        XCTAssertNil(released)
    }
}
