import CryptoKit
import Foundation

enum Verifier {
    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func matches(_ data: Data, sha256Hex expected: String) -> Bool {
        sha256Hex(data) == expected.lowercased()
    }
}
