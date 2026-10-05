import Foundation
import XCTest
@testable import Tarjim

/// Reports are rare by design: once per condition, cleared only when that condition is seen resolved.
final class ReporterTests: XCTestCase {
    private let checksum = String(repeating: "a", count: 64)
    private let fileHash = String(repeating: "b", count: 64)

    private func report(_ outcome: CycleOutcome, _ signals: [CycleSignal] = []) -> CycleReport {
        CycleReport(outcome: outcome, nextCheckIn: 1800, signals: signals)
    }

    private func reporter(_ root: URL, handler: Bool = true) throws -> (Reporter, TestValue<[TarjimReport]>, Store) {
        let store = try StoreFixtures.store(root)
        let seen = TestValue<[TarjimReport]>([])
        var receive: (@Sendable (TarjimReport) -> Void)?
        if handler {
            receive = { @Sendable report in seen.value.append(report) }
        }
        return (Reporter(store: store, handler: receive), seen, store)
    }

    func testAnUnknownSchemaIsReportedOncePerVersionAcrossRelaunches() async throws {
        let root = try StoreFixtures.root(for: self)
        var (reporter, seen, _) = try self.reporter(root)
        await reporter.cycleFinished(report(.rejected(checksum: checksum, .unknownSchema(2)), [.metaAnswered]))
        await reporter.cycleFinished(report(.rejected(checksum: checksum, .unknownSchema(2)), [.metaAnswered]))
        XCTAssertEqual(seen.value.map(\.kind), [.unknownSchemaVersion(2)])
        (reporter, seen, _) = try self.reporter(root)
        await reporter.cycleFinished(report(.rejected(checksum: checksum, .unknownSchema(2)), [.metaAnswered]))
        XCTAssertEqual(seen.value.map(\.kind), [], "delivered before: not again after a relaunch")
        await reporter.cycleFinished(report(.installed(InstallRecord(directory: "1-aaaaaaaa", checksum: checksum, releaseId: nil, owedSlots: [])),
                                            [.metaAnswered, .installed(schemaVersion: 1, hasStrings: true, checksum: checksum)]))
        await reporter.cycleFinished(report(.rejected(checksum: checksum, .unknownSchema(2)), [.metaAnswered]))
        XCTAssertEqual(seen.value.map(\.kind), [.unknownSchemaVersion(2)], "cleared by a known version, then seen again")
    }

    func testNoStringsIsReportedOncePerManifestAndClearedByOneWithStrings() async throws {
        let (reporter, seen, _) = try self.reporter(try StoreFixtures.root(for: self))
        for _ in 0..<2 { await reporter.cycleFinished(report(.rejected(checksum: checksum, .noStrings), [.metaAnswered])) }
        XCTAssertEqual(seen.value.map(\.kind), [.noStringsInRelease(checksum: checksum)])
        await reporter.cycleFinished(report(.unchanged, [.metaAnswered, .installed(schemaVersion: 1, hasStrings: true, checksum: fileHash)]))
        await reporter.cycleFinished(report(.rejected(checksum: checksum, .noStrings), [.metaAnswered]))
        XCTAssertEqual(seen.value.count, 2)
    }

    /// One mismatch can be a cut connection; two cycles in a row are reported, once.
    func testAManifestChecksumMismatchIsReportedOnTheSecondCycleInARow() async throws {
        let (reporter, seen, _) = try self.reporter(try StoreFixtures.root(for: self))
        await reporter.cycleFinished(report(.failed, [.metaAnswered, .manifestChecksumMismatch(metaChecksum: checksum)]))
        XCTAssertEqual(seen.value.count, 0)
        await reporter.cycleFinished(report(.unchanged, [.metaAnswered]))
        await reporter.cycleFinished(report(.failed, [.metaAnswered, .manifestChecksumMismatch(metaChecksum: checksum)]))
        XCTAssertEqual(seen.value.count, 0, "not in a row")
        for _ in 0..<3 { await reporter.cycleFinished(report(.failed, [.metaAnswered, .manifestChecksumMismatch(metaChecksum: checksum)])) }
        XCTAssertEqual(seen.value.map(\.kind), [.manifestChecksumMismatch(checksum: checksum)])
    }

    func testAFileHashMismatchIsReportedOnceAndClearedWhenTheSlotIsNoLongerOwed() async throws {
        let (reporter, seen, _) = try self.reporter(try StoreFixtures.root(for: self))
        for _ in 0..<2 { await reporter.cycleFinished(report(.unchanged, [.metaAnswered, .fileHashMismatch(hash: fileHash), .owed(hashes: [fileHash])])) }
        XCTAssertEqual(seen.value.map(\.kind).filter { if case .fileHashMismatch = $0 { true } else { false } }, [.fileHashMismatch(hash: fileHash)])
        await reporter.cycleFinished(report(.unchanged, [.metaAnswered, .owed(hashes: [])]))
        await reporter.cycleFinished(report(.unchanged, [.metaAnswered, .fileHashMismatch(hash: fileHash), .owed(hashes: [fileHash])]))
        XCTAssertEqual(seen.value.filter { $0.kind == .fileHashMismatch(hash: fileHash) }.count, 2)
    }

    /// An owed slot is normal for a while; three cycles in a row is worth a report.
    func testASlotOwedForThreeCyclesInARowIsReportedOnce() async throws {
        let (reporter, seen, _) = try self.reporter(try StoreFixtures.root(for: self))
        for _ in 0..<2 { await reporter.cycleFinished(report(.unchanged, [.metaAnswered, .owed(hashes: [fileHash])])) }
        await reporter.cycleFinished(report(.unchanged, [.metaAnswered, .owed(hashes: [])]))
        for _ in 0..<2 { await reporter.cycleFinished(report(.unchanged, [.metaAnswered, .owed(hashes: [fileHash])])) }
        XCTAssertEqual(seen.value.count, 0)
        for _ in 0..<3 { await reporter.cycleFinished(report(.unchanged, [.metaAnswered, .owed(hashes: [fileHash])])) }
        XCTAssertEqual(seen.value.map(\.kind), [.fileStillUnavailable(hash: fileHash)])
    }

    /// A revoked key is reported once, and again only after `meta` answered in between.
    func testAConfigurationErrorIsReportedOnceUntilMetaAnswers() async throws {
        let (reporter, seen, _) = try self.reporter(try StoreFixtures.root(for: self))
        for _ in 0..<3 { await reporter.cycleFinished(report(.configurationError(code: "unauthorized"))) }
        XCTAssertEqual(seen.value.map(\.kind), [.configuration(code: "unauthorized")])
        await reporter.cycleFinished(report(.unchanged, [.metaAnswered]))
        await reporter.cycleFinished(report(.configurationError(code: "unauthorized")))
        XCTAssertEqual(seen.value.count, 2)
    }

    func testARevertIsReportedOncePerChecksum() async throws {
        let (reporter, seen, _) = try self.reporter(try StoreFixtures.root(for: self))
        await reporter.reverted(checksum: checksum)
        await reporter.reverted(checksum: checksum)
        XCTAssertEqual(seen.value.map(\.kind), [.revertedAfterLaunchCrashes(checksum: checksum)])
    }

    /// Normal states are never reports: no change, offline, backoff, throttling, 5xx, nothing released yet.
    func testNormalStatesAreNeverReported() async throws {
        let (reporter, seen, _) = try self.reporter(try StoreFixtures.root(for: self))
        for outcome: CycleOutcome in [.notDue, .unchanged, .failed, .unreleased, .skipped, .discardedPending,
                                      .installed(InstallRecord(directory: "1-aaaaaaaa", checksum: checksum, releaseId: nil, owedSlots: []))] {
            await reporter.cycleFinished(report(outcome, [.metaAnswered, .owed(hashes: [])]))
        }
        XCTAssertEqual(seen.value.count, 0)
    }

    /// Without a handler nothing is recorded as delivered, so an app version that adds one still hears it; the debug
    /// log line is written once per process.
    func testWithoutAHandlerNothingIsMarkedDeliveredAndTheLogLineIsWrittenOnce() async throws {
        let root = try StoreFixtures.root(for: self)
        let lines = TestValue<[String]>([])
        Log.setSink { lines.value.append($0) }
        addTeardownBlock { Log.setSink(nil) }
        let (reporter, _, store) = try self.reporter(root, handler: false)
        for _ in 0..<3 { await reporter.cycleFinished(report(.configurationError(code: "unauthorized"))) }
        XCTAssertEqual(lines.value.filter { $0.contains("unauthorized") }.count, 1)
        let state = await store.state
        XCTAssertEqual(state.deliveredReports, [])
        let (later, seen, _) = try self.reporter(root)
        await later.cycleFinished(report(.configurationError(code: "unauthorized")))
        XCTAssertEqual(seen.value.map(\.kind), [.configuration(code: "unauthorized")])
    }
}

final class LogTests: XCTestCase {
    /// One call site: nothing in the SDK prints or logs except through `Log`.
    func testNothingLogsOutsideTheOneCallSite() throws {
        let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Sources/Tarjim")
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
        var offenders: [String] = []
        var scanned = 0
        for case let url as URL in enumerator where url.pathExtension == "swift" && url.lastPathComponent != "Log.swift" {
            scanned += 1
            let text = try String(contentsOf: url, encoding: .utf8)
            for pattern in ["print(", "NSLog(", "os_log(", "Logger(", "debugPrint(", "dump("] where text.contains(pattern) {
                offenders.append("\(url.lastPathComponent): \(pattern)")
            }
        }
        XCTAssertGreaterThan(scanned, 10)
        XCTAssertEqual(offenders, [])
    }

    func testTheSinkSeesDebugMessages() {
        let lines = TestValue<[String]>([])
        Log.setSink { lines.value.append($0) }
        defer { Log.setSink(nil) }
        Log.debug("hello")
        XCTAssertEqual(lines.value, ["hello"])
    }
}

final class CycleSignalTests: XCTestCase {
    private let en = CycleFixtures.enStrings

    func testACycleSaysWhatItSaw() async throws {
        let device = try Device(self)
        let release = try Release.one()
        device.server.publish(release)
        let hash = try release.hash(of: en)
        device.server.answerObject(hash: hash, fileType: "strings", FakeTransport.Answer(status: 200, body: Data("tampered".utf8)))
        let report = try await device.cycle().run()
        XCTAssertTrue(report.signals.contains(.metaAnswered))
        XCTAssertTrue(report.signals.contains(.fileHashMismatch(hash: hash)))
        XCTAssertTrue(report.signals.contains(.owed(hashes: [hash])))
        XCTAssertTrue(report.signals.contains(.installed(schemaVersion: 1, hasStrings: true, checksum: release.checksum)))
    }

    func testAManifestFailingItsChecksumIsSignalled() async throws {
        let device = try Device(self)
        let one = try Release.one()
        let other = try one.changing(releaseId: 42)
        device.server.publish(Release(releaseId: 42, checksum: one.checksum, manifest: other.manifest, metaBody: one.metaBody, objects: [:]))
        let report = try await device.cycle().run()
        XCTAssertTrue(report.signals.contains(.manifestChecksumMismatch(metaChecksum: one.checksum)))
    }

    func testAFailedMetaReadSignalsNothing() async throws {
        let device = try Device(self)
        device.server.answerMeta(FakeTransport.Answer(status: 502))
        let report = try await device.cycle().run()
        XCTAssertEqual(report.signals, [])
    }
}
