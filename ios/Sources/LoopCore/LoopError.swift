import Foundation

/// Typed errors surfaced by Loop modules. The host app should handle
/// `.invalidApiKey` distinctly during integration; everything else is
/// either transient network noise or a backend issue.
public enum LoopError: Error, Sendable, Equatable {
    /// Backend returned 401/403 — the public key is missing, wrong, or
    /// has been deactivated.
    case invalidApiKey

    /// Backend returned 400, often because of a malformed reporter id or
    /// missing required field in the submission body.
    case badRequest(message: String?)

    /// Backend returned 4xx other than 400/401/403 (e.g. 404 on a vote
    /// for an item that doesn't exist in this project).
    case notFound

    /// Backend returned 5xx.
    case serverError(status: Int)

    /// Transport-level failure (offline, timeout, cancelled, TLS, etc.).
    case transport(URLError.Code)

    /// JSON could not be decoded.
    case decoding(String)

    /// Catch-all for the rare case a response is HTTP but neither
    /// success nor a known error shape.
    case unknown(status: Int)
}
