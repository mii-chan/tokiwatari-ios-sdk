#if DEBUG
import Foundation
import GRDB

/// A row of the `events` table. The snake_case column names (via `CodingKeys`)
/// and GRDB's `"yyyy-MM-dd HH:mm:ss.SSS"` UTC storage format for `timestamp`
/// are both part of the CLI contract.
struct EventRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "events"

    var sessionId: String
    var sessionSequence: Int64
    var timestamp: Date
    var eventKind: String        // "api" | "ui"
    var identifier: String?
    var httpMethod: String?
    var url: String?
    var statusCode: Int?
    var durationMs: Int?
    var payloadJson: String?

    enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case sessionSequence = "session_sequence"
        case timestamp = "timestamp"
        case eventKind = "event_kind"
        case identifier = "identifier"
        case httpMethod = "http_method"
        case url = "url"
        case statusCode = "status_code"
        case durationMs = "duration_ms"
        case payloadJson = "payload_json"
    }
}
#endif
