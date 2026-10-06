import CryptoKit
import Foundation
import Network

/// One file of a release: a `.strings` table or a one-key `.stringsdict` plural.
enum StubFile: Sendable {
    case strings(namespace: String, locale: String, [String: String])
    case plural(namespace: String, locale: String, key: String, one: String, other: String)
}

/// A release the stub serves, built in code; every hash is computed from the bytes it serves.
struct StubRelease: Sendable {
    let releaseId: Int
    let files: [StubFile]
}

/// What the app sent, as the stub received it.
struct StubRequest: Sendable {
    /// Path and query, as on the request line.
    let target: String
    let headers: [String: String]
}

enum StubError: Error {
    case noPort
}

/// A Tarjim delivery server on 127.0.0.1 for the UI tests, in origin delivery mode. The app and the test runner share
/// the host's network on the simulator, so the app reaches it at the URL `start` returns.
final class StubServer: @unchecked Sendable {
    /// What one release looks like on the wire; everything is derived from the bytes in `objects`.
    private struct Built {
        let metaBody: Data
        let etag: String
        let manifestPath: String
        let manifest: Data
        /// `<hash>.<fileType>` to bytes.
        let objects: [String: Data]
    }

    private let queue = DispatchQueue(label: "stub-server")
    private let lock = NSLock()
    private var built: Built
    private var recorded: [StubRequest] = []
    private var listener: NWListener?
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private var sequence = 1

    init(release: StubRelease) {
        built = Self.build(release, sequence: 1)
    }

    /// Starts listening on an ephemeral port and returns `http://localhost:<port>`.
    func start() throws -> URL {
        let parameters = NWParameters.tcp
        // The SDK only allows plain http to a loopback name; bind there so nothing else on the network can answer.
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready, .failed, .cancelled: ready.signal()
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        listener.start(queue: queue)
        guard ready.wait(timeout: .now() + 10) == .success, let port = listener.port?.rawValue else {
            listener.cancel()
            throw StubError.noPort
        }
        lock.withLock { self.listener = listener }
        return URL(string: "http://localhost:\(port)")!
    }

    /// Closes the listener; the port then refuses connections.
    func stop() {
        let (listener, open) = lock.withLock { () -> (NWListener?, [NWConnection]) in
            defer { self.listener = nil; connections = [:] }
            return (self.listener, Array(connections.values))
        }
        guard let listener else { return }
        let closed = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { if case .cancelled = $0 { closed.signal() } }
        listener.cancel()
        open.forEach { $0.cancel() }
        _ = closed.wait(timeout: .now() + 5)
    }

    /// Serves `release` from the next request on.
    func publish(_ release: StubRelease) {
        lock.withLock {
            sequence += 1
            built = Self.build(release, sequence: sequence)
        }
    }

    /// Every request received so far, in order.
    var requests: [StubRequest] { lock.withLock { recorded } }

    // MARK: connections

    private func accept(_ connection: NWConnection) {
        let id = ObjectIdentifier(connection)
        lock.withLock { connections[id] = connection }
        connection.stateUpdateHandler = { [weak self] state in
            if case .cancelled = state { self?.lock.withLock { _ = self?.connections.removeValue(forKey: id) } }
        }
        connection.start(queue: queue)
        receive(on: connection, buffered: Data())
    }

    private func receive(on connection: NWConnection, buffered: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var bytes = buffered
            if let data { bytes.append(data) }
            if let end = bytes.range(of: Data("\r\n\r\n".utf8)) {
                self.respond(to: bytes[..<end.lowerBound], on: connection)
            } else if error != nil || isComplete || bytes.count > 65_536 {
                connection.cancel()
            } else {
                self.receive(on: connection, buffered: bytes)
            }
        }
    }

    private func respond(to head: Data, on connection: NWConnection) {
        let lines = (String(data: head, encoding: .utf8) ?? "").components(separatedBy: "\r\n")
        let parts = lines.first?.split(separator: " ") ?? []
        guard parts.count >= 2 else { return connection.cancel() }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[String(line[..<colon])] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let target = String(parts[1])
        let current = lock.withLock { () -> Built in
            recorded.append(StubRequest(target: target, headers: headers))
            return built
        }
        let (status, extra, body) = Self.answer(target: target, headers: headers, release: current)
        var response = "HTTP/1.1 \(status) \(status == 200 ? "OK" : status == 304 ? "Not Modified" : "Not Found")\r\n"
        for (name, value) in extra { response += "\(name): \(value)\r\n" }
        response += "Content-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(response.utf8) + body, contentContext: .finalMessage, isComplete: true,
                        completion: .contentProcessed { _ in connection.cancel() })
    }

    private static func answer(target: String, headers: [String: String], release: Built) -> (Int, [String: String], Data) {
        let path = target.split(separator: "?", maxSplits: 1).first.map(String.init) ?? target
        if path.hasSuffix("/delivery/meta") {
            let match = headers.first { $0.key.lowercased() == "if-none-match" }?.value
            if match == release.etag { return (304, ["ETag": release.etag], Data()) }
            return (200, ["Content-Type": "application/json; charset=utf-8", "ETag": release.etag], release.metaBody)
        }
        if path.hasSuffix(release.manifestPath) {
            return (200, ["Content-Type": "application/json; charset=utf-8"], release.manifest)
        }
        if let bytes = release.objects[(path as NSString).lastPathComponent] {
            return (200, ["Content-Type": "application/octet-stream"], bytes)
        }
        return (404, ["Content-Type": "application/problem+json"], Data(#"{"status":404,"code":"not_found","title":"not_found"}"#.utf8))
    }

    // MARK: building a release

    private static func build(_ release: StubRelease, sequence: Int) -> Built {
        // One namespace bundle per namespace name, ids `ns1`, `ns2`, ... in order of first use.
        var bundleIds: [String: String] = [:]
        var objects: [String: Data] = [:]
        var slices: [String: [String: [String: [String: Any]]]] = [:]
        func add(_ namespace: String, _ locale: String, _ fileType: String, _ bytes: Data) {
            if bundleIds[namespace] == nil { bundleIds[namespace] = "ns\(bundleIds.count + 1)" }
            let hash = hex(bytes)
            objects["\(hash).\(fileType)"] = bytes
            slices[bundleIds[namespace]!, default: [:]][locale, default: [:]][fileType] = ["hash": hash, "size": bytes.count]
        }
        for file in release.files {
            switch file {
            case let .strings(namespace, locale, table): add(namespace, locale, "strings", stringsBytes(table))
            case let .plural(namespace, locale, key, one, other):
                add(namespace, locale, "stringsdict", stringsdictBytes(key: key, one: one, other: other))
            }
        }
        var named: [String: [String: String]] = [:]
        for (name, id) in bundleIds { named[id] = ["type": "namespace", "name": name] }
        let manifestObject: [String: Any] = ["schemaVersion": 1, "baseLocale": "en", "bundles": named, "slices": slices]
        let manifest = try! JSONSerialization.data(withJSONObject: manifestObject, options: .sortedKeys)
        let checksum = hex(manifest)
        let manifestPath = "released/\(release.releaseId)/manifest"
        let etag = "\"m\(sequence)-\(checksum)\""
        let meta: [String: Any] = [
            "projectId": 1, "generation": release.releaseId, "checksum": checksum, "schemaVersion": 1,
            "manifestUrl": manifestPath, "slicesBaseUrl": "released/slices/", "authenticated": true,
            "track": "ios", "stage": "production", "releaseId": release.releaseId, "sequence": sequence,
            "pollAfter": 60,
        ]
        let metaBody = try! JSONSerialization.data(withJSONObject: meta, options: .sortedKeys)
        return Built(metaBody: metaBody, etag: etag, manifestPath: manifestPath, manifest: manifest, objects: objects)
    }

    private static func hex(_ bytes: Data) -> String {
        SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }

    private static func escaped(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
    }

    private static func xml(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
    }

    private static func stringsBytes(_ table: [String: String]) -> Data {
        let lines = table.sorted { $0.key < $1.key }.map { "\"\(escaped($0.key))\" = \"\(escaped($0.value))\";\n" }
        return Data(lines.joined().utf8)
    }

    private static func stringsdictBytes(key: String, one: String, other: String) -> Data {
        Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
          <key>\(xml(key))</key>
          <dict>
            <key>NSStringLocalizedFormatKey</key><string>%#@v@</string>
            <key>v</key>
            <dict>
              <key>NSStringFormatSpecTypeKey</key><string>NSStringPluralRuleType</string>
              <key>NSStringFormatValueTypeKey</key><string>d</string>
              <key>one</key><string>\(xml(one))</string>
              <key>other</key><string>\(xml(other))</string>
            </dict>
          </dict>
        </dict>
        </plist>

        """.utf8)
    }
}
