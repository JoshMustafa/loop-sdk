import Foundation
import LoopCore

protocol DiagnosticsSending: Sendable {
    func send(body: Data) async throws
}

/// POSTs a pre-serialised diagnostic payload to `/api/ingest/events`.
/// The payload carries arbitrary developer-supplied context, so it is built
/// with `JSONSerialization` upstream rather than modelled with Codable.
/// Throws on transport failure or any non-2xx so the engine can buffer it.
struct DiagnosticsClient: DiagnosticsSending {
    let http: LoopHTTP

    func send(body: Data) async throws {
        var request = try http.makeRequest(method: "POST", path: "/api/ingest/events")
        request.httpBody = body
        try await http.executeNoContent(request)
    }
}
