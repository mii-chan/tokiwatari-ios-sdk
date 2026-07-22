#if DEBUG
import Foundation
import GRDB
import Synchronization
@testable import Tokiwatari

func makeTemporaryDatabaseURL() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("tokiwatari-tests", isDirectory: true)
        .appendingPathComponent(UUID().uuidString + ".sqlite")
}

func makeTemporaryDatabase() throws -> TokiwatariDatabase {
    try TokiwatariDatabase(url: makeTemporaryDatabaseURL())
}

/// The storage format of `timestamp` — part of the contract with the CLI.
func makeContractTimestampFormatter() -> DateFormatter {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(identifier: "UTC")
    formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
    return formatter
}

// MARK: - End-to-end helpers (shared global SDK state, so serialized)

/// Tokiwatari's configuration is process-global; every test that goes through
/// `configure` must hold this lock.
let tokiwatariGlobalStateLock = NSLock()

struct RecordedEvent {
    var sessionId: String
    var sessionSequence: Int64
    var eventKind: String
    var identifier: String?
    var httpMethod: String?
    var url: String?
    var statusCode: Int?
    var durationMs: Int?
    var payloadJson: String?

    var payload: [String: Any] {
        guard let payloadJson,
              let object = try? JSONSerialization.jsonObject(with: Data(payloadJson.utf8)) as? [String: Any]
        else { return [:] }
        return object
    }

    subscript(path: String...) -> Any? {
        var current: Any? = payload
        for component in path {
            current = (current as? [String: Any])?[component]
        }
        return current
    }
}

final class CountingSession: TokiwatariSessionProviding {
    private let state = Mutex<(id: String, sequence: Int64)>(("test-session", 0))

    func next() -> (sessionId: String, sequence: Int64) {
        state.withLock { s in
            s.sequence += 1
            return (s.id, s.sequence)
        }
    }

    var currentId: String { state.withLock { $0.id } }
}

/// Configures the SDK against a temporary database, runs `body`, flushes the
/// writer queue and returns all recorded events in insertion order.
func recordedEvents(
    allowedQueryParameters: [String] = [],
    additionalSensitiveHeaderNames: [String] = [],
    additionalSensitiveBodyKeys: [String] = [],
    maximumPayloadBytesForTesting: Int? = nil,
    _ body: () throws -> Void
) throws -> [RecordedEvent] {
    tokiwatariGlobalStateLock.lock()
    defer { tokiwatariGlobalStateLock.unlock() }

    Tokiwatari.configure(
        session: CountingSession(),
        allowedQueryParameters: allowedQueryParameters,
        additionalSensitiveHeaderNames: additionalSensitiveHeaderNames,
        additionalSensitiveBodyKeys: additionalSensitiveBodyKeys,
        maximumPayloadBytesForTesting: maximumPayloadBytesForTesting,
        databaseURL: makeTemporaryDatabaseURL()
    )
    guard let database = Tokiwatari.databaseForTesting else {
        throw TestSupportError.databaseUnavailable
    }
    try body()
    try database.flushPendingWrites()
    return try database.pool.read { db in
        try Row.fetchAll(db, sql: "SELECT * FROM events ORDER BY session_sequence").map { row in
            RecordedEvent(
                sessionId: row["session_id"],
                sessionSequence: row["session_sequence"],
                eventKind: row["event_kind"],
                identifier: row["identifier"],
                httpMethod: row["http_method"],
                url: row["url"],
                statusCode: row["status_code"],
                durationMs: row["duration_ms"],
                payloadJson: row["payload_json"]
            )
        }
    }
}

enum TestSupportError: Error {
    case databaseUnavailable
}

func makeRequest(
    _ urlString: String = "https://api.tokiwatari.test/v1/teas",
    method: String = "GET",
    headers: [String: String] = [:],
    body: Data? = nil,
    contentType: String? = nil
) -> URLRequest {
    var request = URLRequest(url: URL(string: urlString)!)
    request.httpMethod = method
    for (name, value) in headers {
        request.setValue(value, forHTTPHeaderField: name)
    }
    if let contentType {
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
    }
    request.httpBody = body
    return request
}

func makeResponse(
    _ urlString: String = "https://api.tokiwatari.test/v1/teas",
    statusCode: Int = 200,
    headers: [String: String] = [:]
) -> HTTPURLResponse {
    HTTPURLResponse(
        url: URL(string: urlString)!,
        statusCode: statusCode,
        httpVersion: "HTTP/1.1",
        headerFields: headers
    )!
}
#endif
