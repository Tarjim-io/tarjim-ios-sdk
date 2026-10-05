import Foundation

/// One case per kind of `meta` answer the SDK must handle.
enum MetaOutcome: Sendable, Equatable {
    /// 200 with a body the SDK could read, and the ETag to send next time. Whether anything
    /// changed is decided by comparing `checksum` with the newest manifest held, never by this case.
    case received(Meta, etag: String?, raw: Data)
    /// 304.
    case notModified
    /// 200 with a body that does not decode. Keep what is held.
    case unreadable
    /// 400, 401, 403, or 404 with any code but an "unreleased" one: the configuration is wrong until
    /// `meta` answers 200 again.
    case configurationError(code: String, pollAfter: Int?)
    /// 404 `delivery.stage_unreleased` (or the older `delivery.track_unreleased` /
    /// `delivery.not_published`): nothing released yet. Normal, silent.
    case unreleased(pollAfter: Int?)
    /// 429.
    case throttled(retryAfter: Int?)
    /// 5xx, 3xx (redirects are never followed) and anything else: back off, keep what is held.
    case serverError(retryAfter: Int?)
    /// The transport threw.
    case networkFailure
}

enum ManifestOutcome: Sendable, Equatable {
    /// The bytes hash to `meta.checksum` and decode.
    case verified(Manifest, raw: Data)
    /// The bytes do not hash to `meta.checksum`; treated as a failed fetch.
    case checksumMismatch
    /// The bytes hash correctly but do not decode. Keep what is held.
    case unreadable
    /// `meta` named a URL the SDK will not request (it would leave the host, or is malformed).
    /// Not retried until `meta` changes.
    case refused
    /// A 4xx other than 429, or a 503, on the object: unfetchable this cycle.
    case unfetchable(status: Int, retryAfter: Int?)
    case throttled(retryAfter: Int?)
    case serverError(retryAfter: Int?)
    case networkFailure
}

enum ObjectOutcome: Sendable, Equatable {
    /// The bytes hash to the manifest's `hash` (and fit `size` when one was given).
    case verified(Data)
    /// The bytes do not hash to `hash`; they are discarded.
    case hashMismatch
    /// More bytes than the manifest's `size`; refused before being kept.
    case tooLarge
    /// The manifest entry or `meta` named something the SDK will not request. Not retried until
    /// `meta` changes.
    case refused
    /// A 4xx other than 429, or a 503, on the object: unfetchable this cycle.
    case unfetchable(status: Int, retryAfter: Int?)
    case throttled(retryAfter: Int?)
    case serverError(retryAfter: Int?)
    case networkFailure
}
