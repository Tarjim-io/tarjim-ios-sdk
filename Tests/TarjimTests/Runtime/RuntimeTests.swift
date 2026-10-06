import Foundation
import XCTest
@testable import Tarjim

/// A device running the SDK as an app would: same root across `make()` calls, a server, a clock.
final class RuntimeHarness {
    let root: URL
    let server = DeliveryServer()
    let clock = TestClock()
    let appBundle: Bundle
    let reports = TestValue<[TarjimReport]>([])
    let sleeps = TestValue<[TimeInterval]>([])
    /// Waits that return at once; after these, a wait lasts until its task is cancelled (as a real timer would).
    let instantSleeps = TestValue<Int>(1_000)
    /// Ends every wait still blocked (a timer that was never cancelled would then run on).
    let releaseBlockedSleeps = TestValue<Bool>(false)
    let appLanguage = TestValue<String>("en")

    init(_ test: XCTestCase) throws {
        root = try StoreFixtures.root(for: test)
        appBundle = try LookupFixtures.appBundle(for: test)
    }

    func configuration(apiKey: String = DeliveryFixtures.apiKey, sendsInstallIdentifier: Bool = true) -> TarjimConfiguration {
        var configuration = TarjimConfiguration(projectId: DeliveryFixtures.projectId, apiKey: apiKey, host: DeliveryFixtures.host,
                                                defaultBundle: .namespace("default"), fallbackLanguage: "en")
        let reports = self.reports
        configuration.onReport = { report in reports.value.append(report) }
        configuration.sendsInstallIdentifier = sendsInstallIdentifier
        return configuration
    }

    func make(_ configuration: TarjimConfiguration? = nil, transport: (any Transport)? = nil) throws -> Runtime {
        let clock = self.clock, sleeps = self.sleeps, instantSleeps = self.instantSleeps
        let release = self.releaseBlockedSleeps, appLanguage = self.appLanguage
        let environment = Runtime.Environment(root: root, transport: transport ?? server, appBundle: appBundle,
                                              preferences: { ["en-US"] }, appLanguage: { appLanguage.value }, now: { clock.now },
                                              random: { 0 }, sleep: { seconds in
                                                  sleeps.value.append(seconds)
                                                  if sleeps.value.count > instantSleeps.value {
                                                      while !Task.isCancelled, !release.value {
                                                          try? await Task.sleep(nanoseconds: 1_000_000)
                                                      }
                                                  }
                                              },
                                              sdkVersion: "0.1.0", appVersion: "2.3.1", osVersion: "17.4")
        return try Runtime(configuration: configuration ?? self.configuration(), environment: environment)
    }
}

final class RuntimeTests: XCTestCase {
    func testBeforeStartLookupsUseTheAppsOwnText() throws {
        let runtime = try RuntimeHarness(self).make()
        XCTAssertEqual(runtime.string("app.only", bundle: nil), "From the app")
        XCTAssertEqual(runtime.string("no.such.key", bundle: nil), "no.such.key")
    }

    func testAStartedRuntimeServesTheFirstDownload() async throws {
        let harness = try RuntimeHarness(self)
        harness.server.publish(try Release.one())
        let runtime = try harness.make()
        let seen = TestValue<[TarjimUpdate]>([])
        let stream = runtime.updates()
        Task { for await update in stream { seen.value.append(update) } }
        await runtime.start(foreground: true)
        await runtime.checkNow()
        XCTAssertEqual(runtime.string("app.title", bundle: nil), "Tarjim")
        XCTAssertEqual(runtime.string("greeting", arguments: ["Sam"], bundle: nil), "Hello, Sam!")
        XCTAssertEqual(runtime.locale.identifier, "en")
        await EngineFixtures.settle(until: { seen.value.count >= 2 })
        XCTAssertEqual(seen.value, [.downloaded, .activated])
    }

    func testConditionsReachTheAppsHandler() async throws {
        let harness = try RuntimeHarness(self)
        harness.server.publish(try Release.one().changing(releaseId: 43, fields: ["schemaVersion": 2]))
        let runtime = try harness.make()
        await runtime.start(foreground: true)
        await runtime.checkNow()
        harness.clock.advance(1800)
        await runtime.checkNow()
        XCTAssertEqual(harness.reports.value.map(\.kind), [.unknownSchemaVersion(2)])
    }

    /// The app is told when a release was reverted because it crashed the app at launch.
    func testARevertIsReported() async throws {
        let harness = try RuntimeHarness(self)
        harness.server.publish(try Release.one())
        let first = try harness.make()
        await first.start(foreground: true)
        await first.checkNow()
        for _ in 0..<2 { await (try harness.make()).start(foreground: true) }
        XCTAssertEqual(harness.reports.value.map(\.kind), [.revertedAfterLaunchCrashes(checksum: try Release.one().checksum)])
    }

    /// The key never reaches a log line, whatever happens.
    func testTheKeyIsNeverLogged() async throws {
        let lines = TestValue<[String]>([])
        Log.setSink { lines.value.append($0) }
        addTeardownBlock { Log.setSink(nil) }
        var configuration = try RuntimeHarness(self).configuration()
        configuration.onReport = nil
        let harness = try RuntimeHarness(self)
        harness.server.answerMeta(CycleFixtures.problem(401, code: "unauthorized"))
        let runtime = try harness.make(configuration)
        await runtime.start(foreground: true)
        await runtime.checkNow()
        XCTAssertFalse(lines.value.isEmpty, "the configuration problem was logged")
        XCTAssertFalse(lines.value.contains { $0.contains(DeliveryFixtures.apiKey) })
    }

    /// One random identifier per install, sent only when the app allows it.
    func testTheInstallIdentifierIsStableAndOptional() async throws {
        let harness = try RuntimeHarness(self)
        harness.server.publish(try Release.one())
        for _ in 0..<2 {
            let runtime = try harness.make()
            await runtime.start(foreground: true)
            harness.clock.advance(3600)
            await runtime.checkNow()
        }
        let agents = harness.server.metaRequests.compactMap { $0.value(forHTTPHeaderField: "User-Agent") }
        XCTAssertEqual(agents.count, 2)
        let identifiers = agents.compactMap { $0.components(separatedBy: " install/").dropFirst().first }
        XCTAssertEqual(identifiers.count, 2)
        XCTAssertEqual(Set(identifiers).count, 1, "stable across launches")
        XCTAssertNotNil(UUID(uuidString: identifiers[0]))

        let off = try RuntimeHarness(self)
        off.server.publish(try Release.one())
        let runtime = try off.make(off.configuration(sendsInstallIdentifier: false))
        await runtime.start(foreground: true)
        await runtime.checkNow()
        let agent = try XCTUnwrap(off.server.metaRequests.first?.value(forHTTPHeaderField: "User-Agent"))
        XCTAssertFalse(agent.contains("install/"))
    }

    /// An app version built with another key starts empty, and the old key's files are removed.
    func testAnotherKeyNeverSeesTheOldKeysFiles() async throws {
        let harness = try RuntimeHarness(self)
        harness.server.publish(try Release.one())
        let old = try harness.make()
        await old.start(foreground: true)
        await old.checkNow()
        let oldStore = harness.root.appendingPathComponent("Tarjim/v1/\(StoreIdentifier.make(host: DeliveryFixtures.host, projectId: DeliveryFixtures.projectId, apiKey: DeliveryFixtures.apiKey))")
        XCTAssertTrue(StoreFixtures.exists(oldStore))
        let renewed = try harness.make(harness.configuration(apiKey: "another-test-key-0123456789"))
        await renewed.start(foreground: true)
        XCTAssertEqual(renewed.string("app.title", bundle: nil), "app.title")
        XCTAssertFalse(StoreFixtures.exists(oldStore))
    }

    func testTheAppLanguageIsNeverBase() throws {
        let directory = try LookupFixtures.temporaryDirectory(for: self).appendingPathComponent("Storyboards.bundle", isDirectory: true)
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("Base.lproj"), withIntermediateDirectories: true)
        try Data("\"a\" = \"b\";".utf8).write(to: directory.appendingPathComponent("Base.lproj/Main.strings"))
        let info: [String: Any] = ["CFBundleIdentifier": "com.example.storyboards", "CFBundleDevelopmentRegion": "ar"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: directory.appendingPathComponent("Info.plist"))
        XCTAssertEqual(Runtime.appLanguage(of: try XCTUnwrap(Bundle(url: directory))), "ar")
        XCTAssertEqual(Runtime.appLanguage(of: try LookupFixtures.appBundle(for: self)), "en")
    }

    /// The schedule waits the launch delay first, then each cycle's `nextCheckIn`.
    func testTheScheduleWaitsAsTheCycleSays() async throws {
        let harness = try RuntimeHarness(self)
        harness.server.publish(try Release.one())
        let runtime = try harness.make()
        await runtime.start(foreground: true)
        await runtime.runSchedule(iterations: 2)
        XCTAssertEqual(harness.sleeps.value, [0, 1800], "the launch delay, then the first check's nextCheckIn")
        XCTAssertEqual(runtime.string("app.title", bundle: nil), "Tarjim")
    }
}

final class PublicAPITests: XCTestCase {
    func testTheConfigurationNeedsOnlyWhatHasNoSafeDefault() {
        let configuration = TarjimConfiguration(projectId: 7, apiKey: "k", host: URL(string: "https://api.example.invalid")!,
                                                defaultBundle: .custom("home"), fallbackLanguage: "en")
        XCTAssertTrue(configuration.sendsInstallIdentifier)
        XCTAssertTrue(configuration.interceptsMainBundle)
        XCTAssertNil(configuration.onReport)
    }

    /// Before `start`, a lookup answers from the app's own resources — here none — so the key comes back, never "".
    func testALookupBeforeStartIsTheKey() {
        XCTAssertEqual(Tarjim.string("tarjim.public.api.test.missing"), "tarjim.public.api.test.missing")
    }
}
