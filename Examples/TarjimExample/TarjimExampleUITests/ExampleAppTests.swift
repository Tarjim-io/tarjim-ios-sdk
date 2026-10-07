import XCTest

/// Drives the example app against the stub server: download, install, activation and lookups through a real
/// SwiftUI view, a storyboard and the public API.
@MainActor
final class ExampleAppTests: XCTestCase {
    private let apiKey = "example-test-key"
    private var server: StubServer!

    // The first check of a launch waits up to 30 s; the next comes no sooner than 60 s (72 s with jitter).
    private let firstCheck: TimeInterval = 60
    private let secondCheck: TimeInterval = 150
    // How long a change already under way may take to show; a busy shared CI simulator can take many seconds to
    // even read the screen.
    private let readiness: TimeInterval = 30

    override func setUp() async throws {
        continueAfterFailure = false
        server = StubServer(release: .first)
    }

    override func tearDown() async throws {
        server.stop()
    }

    private func launch(host: URL, reset: Bool) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment = [
            "TARJIM_EXAMPLE_HOST": host.absoluteString,
            "TARJIM_EXAMPLE_PROJECT_ID": "1",
            "TARJIM_EXAMPLE_API_KEY": apiKey,
        ]
        if reset { app.launchArguments = ["-TarjimExampleReset"] }
        app.launch()
        return app
    }

    private func text(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.staticTexts[identifier]
    }

    private func wait(_ element: XCUIElement, toRead value: String, timeout: TimeInterval,
                      file: StaticString = #filePath, line: UInt = #line) {
        let reads = NSPredicate(format: "label == %@", value)
        let expectation = XCTNSPredicateExpectation(predicate: reads, object: element)
        let result = XCTWaiter().wait(for: [expectation], timeout: timeout)
        XCTAssertEqual(result, .completed, "\(element) reads \"\(element.exists ? element.label : "<missing>")\", not \"\(value)\"",
                       file: file, line: line)
    }

    func testFirstLaunchShowsTheDownloadedTextEverywhere() throws {
        let app = launch(host: try server.start(), reset: true)
        wait(text(app, "status"), toRead: "activated", timeout: firstCheck)
        wait(text(app, "proxied"), toRead: "Hello from Tarjim", timeout: readiness)
        wait(text(app, "explicit"), toRead: "Hello from Tarjim", timeout: readiness)
        wait(text(app, "storyboard"), toRead: "Storyboard from Tarjim", timeout: readiness)
        wait(text(app, "formatted"), toRead: "3 items from Tarjim", timeout: readiness)
    }

    func testARelaunchWithoutTheServerKeepsTheDownloadedText() throws {
        let host = try server.start()
        let first = launch(host: host, reset: true)
        wait(text(first, "status"), toRead: "activated", timeout: firstCheck)
        first.terminate()
        server.stop()
        let second = launch(host: host, reset: false)
        wait(text(second, "proxied"), toRead: "Hello from Tarjim", timeout: readiness)
        wait(text(second, "storyboard"), toRead: "Storyboard from Tarjim", timeout: readiness)
    }

    func testChoosingALanguageChangesTarjimText() throws {
        let app = launch(host: try server.start(), reset: true)
        wait(text(app, "status"), toRead: "activated", timeout: firstCheck)
        app.buttons["lang-ar"].tap()
        wait(text(app, "proxied"), toRead: "مرحبا من ترجم", timeout: readiness)
        wait(text(app, "explicit"), toRead: "مرحبا من ترجم", timeout: readiness)
        wait(text(app, "storyboard"), toRead: "القصة من ترجم", timeout: readiness)
        app.buttons["lang-system"].tap()
        wait(text(app, "proxied"), toRead: "Hello from Tarjim", timeout: readiness)
        wait(text(app, "explicit"), toRead: "Hello from Tarjim", timeout: readiness)
        wait(text(app, "storyboard"), toRead: "Storyboard from Tarjim", timeout: readiness)
    }

    func testWhenTheServerFailsTheAppShowsItsOwnText() throws {
        server.failEverything()
        let app = launch(host: try server.start(), reset: true)
        wait(text(app, "proxied"), toRead: "Hello from the app", timeout: readiness)
        wait(text(app, "storyboard"), toRead: "Storyboard from the app", timeout: readiness)
        // Past the longest launch delay, so the failed check has happened.
        _ = XCTWaiter().wait(for: [XCTestExpectation(description: "first check")], timeout: 35)
        XCTAssertFalse(server.requests.isEmpty, "the app asked and was refused")
        XCTAssertEqual(app.state, .runningForeground)
        XCTAssertEqual(text(app, "status").label, "none")
        XCTAssertEqual(text(app, "proxied").label, "Hello from the app")
    }

    func testANewReleaseWaitsForActivation() throws {
        let app = launch(host: try server.start(), reset: true)
        wait(text(app, "status"), toRead: "activated", timeout: firstCheck)
        server.publish(.second)
        wait(text(app, "status"), toRead: "downloaded", timeout: secondCheck)
        // Long enough for a wrong activation to show; nothing may change before the tap.
        _ = XCTWaiter().wait(for: [XCTestExpectation(description: "settle")], timeout: 3)
        XCTAssertEqual(text(app, "status").label, "downloaded")
        XCTAssertEqual(text(app, "proxied").label, "Hello from Tarjim")
        app.buttons["activate"].tap()
        wait(text(app, "proxied"), toRead: "Hello again from Tarjim", timeout: readiness)
        wait(text(app, "status"), toRead: "activated", timeout: readiness)
    }

    /// The next cold start shows a downloaded release, and says so: the app's listener exists before `start`.
    func testTheNextColdStartShowsTheDownloadedReleaseAndSaysSo() throws {
        let host = try server.start()
        let first = launch(host: host, reset: true)
        wait(text(first, "status"), toRead: "activated", timeout: firstCheck)
        server.publish(.second)
        wait(text(first, "status"), toRead: "downloaded", timeout: secondCheck)
        first.terminate()
        let second = launch(host: host, reset: false)
        wait(text(second, "proxied"), toRead: "Hello again from Tarjim", timeout: readiness)
        wait(text(second, "status"), toRead: "activated", timeout: readiness)
    }

    func testTheKeyTravelsOnlyInItsHeader() throws {
        let app = launch(host: try server.start(), reset: true)
        wait(text(app, "status"), toRead: "activated", timeout: firstCheck)
        let requests = server.requests
        XCTAssertFalse(requests.isEmpty)
        for request in requests {
            XCTAssertFalse(request.target.contains(apiKey), request.target)
            let named = request.headers.first { $0.key.lowercased() == "x-tarjim-apikey" }
            XCTAssertEqual(named?.value, apiKey, request.target)
            for (name, value) in request.headers where name.lowercased() != "x-tarjim-apikey" {
                XCTAssertFalse(value.contains(apiKey), "\(name) carries the key")
            }
        }
    }
}
