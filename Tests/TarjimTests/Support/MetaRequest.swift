import Foundation

/// Reads what a `meta` request says about the app: its query parameters, decoded.
enum MetaRequest {
    static func query(_ request: URLRequest?) -> [String: String] {
        guard let url = request?.url, let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else { return [:] }
        return Dictionary(items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { first, _ in first })
    }

    static func withoutQuery(_ url: URL?) -> URL? {
        guard let url, var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        parts.query = nil
        return parts.url
    }
}
