import CryptoKit
import Foundation
import XCTest

/// A recorded (or hand-built) HTTP answer: `Fixtures/**/<name>.json`.
struct ResponseEnvelope: Decodable {
    let provenance: String
    let status: Int
    let headers: [String: String]
    let body: String?

    func header(_ name: String) -> String? {
        headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    func jsonBody() throws -> [String: Any] {
        let data = try XCTUnwrap(body?.data(using: .utf8), "envelope has no body")
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any], "body is not a JSON object")
    }
}

enum Fixtures {
    static var root: URL {
        get throws {
            try XCTUnwrap(Bundle.module.url(forResource: "Fixtures", withExtension: nil), "Fixtures resource missing")
        }
    }

    static func url(_ relativePath: String) throws -> URL {
        try root.appendingPathComponent(relativePath)
    }

    static func data(_ relativePath: String) throws -> Data {
        try Data(contentsOf: url(relativePath))
    }

    static func envelope(_ relativePath: String) throws -> ResponseEnvelope {
        try JSONDecoder().decode(ResponseEnvelope.self, from: data(relativePath))
    }

    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Every regular file under `Fixtures/`, as paths relative to it.
    static func allFiles() throws -> [String] {
        let base = try root.resolvingSymlinksInPath()
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: base, includingPropertiesForKeys: [.isRegularFileKey]))
        var paths: [String] = []
        for case let url as URL in enumerator where (try url.resourceValues(forKeys: [.isRegularFileKey])).isRegularFile == true {
            paths.append(String(url.resolvingSymlinksInPath().path.dropFirst(base.path.count + 1)))
        }
        return paths.sorted()
    }
}
