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
        wait(text(app, "proxied"), toRead: "Hello from Tarjim", timeout: 5)
        wait(text(app, "explicit"), toRead: "Hello from Tarjim", timeout: 5)
        wait(text(app, "storyboard"), toRead: "Storyboard from Tarjim", timeout: 5)
        wait(text(app, "formatted"), toRead: "3 items from Tarjim", timeout: 5)
    }

    func testARelaunchWithoutTheServerKeepsTheDownloadedText() throws {
        let host = try server.start()
        let first = launch(host: host, reset: true)
        wait(text(first, "status"), toRead: "activated", timeout: firstCheck)
        first.terminate()
        server.stop()
        let second = launch(host: host, reset: false)
        wait(text(second, "proxied"), toRead: "Hello from Tarjim", timeout: 10)
        wait(text(second, "storyboard"), toRead: "Storyboard from Tarjim", timeout: 5)
    }

    func testChoosingALanguageChangesOnlyTarjimText() throws {
        let app = launch(host: try server.start(), reset: true)
        wait(text(app, "status"), toRead: "activated", timeout: firstCheck)
        app.buttons["lang-ar"].tap()
        wait(text(app, "proxied"), toRead: "مرحبا من ترجم", timeout: 10)
        wait(text(app, "explicit"), toRead: "مرحبا من ترجم", timeout: 5)
        wait(text(app, "storyboard"), toRead: "القصة من ترجم", timeout: 5)
        app.buttons["lang-system"].tap()
        wait(text(app, "proxied"), toRead: "Hello from Tarjim", timeout: 10)
    }

    func testWithoutAServerTheAppShowsItsOwnText() throws {
        let host = try server.start()
        server.stop()
        let app = launch(host: host, reset: true)
        wait(text(app, "proxied"), toRead: "Hello from the app", timeout: 10)
        wait(text(app, "storyboard"), toRead: "Storyboard from the app", timeout: 5)
        // Past the longest launch delay, so the failed check has happened.
        _ = XCTWaiter().wait(for: [XCTestExpectation(description: "first check")], timeout: 35)
        XCTAssertEqual(app.state, .runningForeground)
        XCTAssertEqual(text(app, "status").label, "none")
        XCTAssertEqual(text(app, "proxied").label, "Hello from the app")
    }

    func testANewReleaseWaitsForActivation() throws {
        let app = launch(host: try server.start(), reset: true)
        wait(text(app, "status"), toRead: "activated", timeout: firstCheck)
        server.publish(.second)
        wait(text(app, "status"), toRead: "downloaded", timeout: secondCheck)
        XCTAssertEqual(text(app, "proxied").label, "Hello from Tarjim")
        app.buttons["activate"].tap()
        wait(text(app, "proxied"), toRead: "Hello again from Tarjim", timeout: 10)
        wait(text(app, "status"), toRead: "activated", timeout: 5)
    }

    func testTheKeyTravelsOnlyInItsHeader() throws {
        let app = launch(host: try server.start(), reset: true)
        wait(text(app, "status"), toRead: "activated", timeout: firstCheck)
        let requests = server.requests
        XCTAssertFalse(requests.isEmpty)
        for request in requests {
            XCTAssertFalse(request.target.contains(apiKey), request.target)
            let named = request.headers.first { $0.key.lowercased() == "x-tarjim-apikey" }
            if request.target.contains("/delivery/meta") { XCTAssertEqual(named?.value, apiKey, request.target) }
            for (name, value) in request.headers where name.lowercased() != "x-tarjim-apikey" {
                XCTAssertFalse(value.contains(apiKey), "\(name) carries the key")
            }
        }
    }
}
