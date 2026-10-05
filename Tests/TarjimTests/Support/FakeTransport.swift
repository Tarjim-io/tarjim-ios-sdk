import Foundation
@testable import Tarjim

/// Replays scripted answers in order and records every request. A request with nothing scripted
/// throws, so a test sees an unexpected extra request as a failure, not a hang.
final class FakeTransport: Transport, @unchecked Sendable {
    struct Answer {
        var status: Int
        var headers: [String: String] = [:]
        var body: Data? = nil

        init(status: Int, headers: [String: String] = [:], body: Data? = nil) {
            self.status = status
            self.headers = headers
            self.body = body
        }

        init(_ envelope: ResponseEnvelope) {
            status = envelope.status
            headers = envelope.headers
            body = envelope.body.map { Data($0.utf8) }
        }

        static func json(_ status: Int, _ object: Any, headers: [String: String] = [:]) -> Answer {
            var all = ["Content-Type": "application/json; charset=utf-8"]
            all.merge(headers) { _, new in new }
            return Answer(status: status, headers: all, body: try! JSONSerialization.data(withJSONObject: object))
        }
    }

    struct Unscripted: Error {}
    struct Offline: Error {}

    private let lock = NSLock()
    private var answers: [Result<Answer, Error>] = []
    private var recorded: [URLRequest] = []

    var requests: [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    func enqueue(_ answer: Answer) {
        lock.lock()
        answers.append(.success(answer))
        lock.unlock()
    }

    func enqueueFailure() {
        lock.lock()
        answers.append(.failure(Offline()))
        lock.unlock()
    }

    private func record(_ request: URLRequest) -> Result<Answer, Error>? {
        lock.lock()
        defer { lock.unlock() }
        recorded.append(request)
        return answers.isEmpty ? nil : answers.removeFirst()
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        guard let next = record(request) else { throw Unscripted() }
        let answer = try next.get()
        let response = HTTPURLResponse(url: request.url!, statusCode: answer.status, httpVersion: "HTTP/1.1", headerFields: answer.headers)!
        return (answer.body ?? Data(), response)
    }
}
