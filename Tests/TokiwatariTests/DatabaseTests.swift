import Foundation
import GRDB
import Testing
@testable import Tokiwatari

@Suite struct DatabaseTests {

    private func createMismatchedDatabase(at url: URL) throws {
        let database = try TokiwatariDatabase(url: url)
        let record = EventRecord(
            sessionId: "old-session",
            sessionSequence: 1,
            timestamp: Date(timeIntervalSince1970: 1_751_700_000),
            eventKind: "ui",
            identifier: "screen_viewed_home",
            httpMethod: nil,
            url: nil,
            statusCode: nil,
            durationMs: nil,
            payloadJson: nil
        )
        try database.pool.write { db in
            try record.insert(db)
            try db.execute(sql: "PRAGMA user_version = 999")
        }
        try database.pool.close()
    }

    @Test func eventRecordRoundtripUsesSnakeCaseColumnsAndContractTimestampFormat() throws {
        let database = try makeTemporaryDatabase()
        let date = Date(timeIntervalSince1970: 1_751_700_000.5)
        let record = EventRecord(
            sessionId: "session-1",
            sessionSequence: 1,
            timestamp: date,
            eventKind: "ui",
            identifier: "tea_tapped_42",
            httpMethod: nil,
            url: nil,
            statusCode: nil,
            durationMs: nil,
            payloadJson: #"{"tea_id":42}"#
        )
        try database.pool.write { try record.insert($0) }

        let row = try #require(try database.pool.read { db in
            try Row.fetchOne(db, sql: """
                SELECT session_id, session_sequence, timestamp, event_kind,
                       identifier, http_method, url, status_code, duration_ms, payload_json
                FROM events
                """)
        })

        let sessionId: String = row["session_id"]
        let sequence: Int64 = row["session_sequence"]
        let eventKind: String = row["event_kind"]
        let identifier: String? = row["identifier"]
        let payloadJson: String? = row["payload_json"]
        #expect(sessionId == "session-1")
        #expect(sequence == 1)
        #expect(eventKind == "ui")
        #expect(identifier == "tea_tapped_42")
        #expect(payloadJson == #"{"tea_id":42}"#)

        let timestampString: String = row["timestamp"]
        let pattern = try Regex(#"^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\.\d{3}$"#)
        #expect(timestampString.wholeMatch(of: pattern) != nil)
        #expect(timestampString == makeContractTimestampFormatter().string(from: date))

        let fetched = try #require(try database.pool.read { try EventRecord.fetchOne($0) })
        #expect(fetched.sessionId == "session-1")
        #expect(fetched.sessionSequence == 1)
        #expect(abs(fetched.timestamp.timeIntervalSince(date)) < 0.001)
    }

    @Test func userVersionIsSetToOne() throws {
        let database = try makeTemporaryDatabase()
        let version = try database.pool.read {
            try Int.fetchOne($0, sql: "PRAGMA user_version")
        }
        #expect(version == 1)
    }

    @Test func purgeKeepsTenNewestSessions() throws {
        let database = try makeTemporaryDatabase()
        let base = Date(timeIntervalSince1970: 1_700_000_000)

        try database.pool.write { db in
            for sessionIndex in 1...12 {
                let sessionId = String(format: "s%02d", sessionIndex)
                for sequence in 1...3 {
                    let record = EventRecord(
                        sessionId: sessionId,
                        sessionSequence: Int64(sequence),
                        timestamp: base.addingTimeInterval(Double(sessionIndex) * 60 + Double(sequence)),
                        eventKind: "ui",
                        identifier: "event_\(sequence)",
                        httpMethod: nil,
                        url: nil,
                        statusCode: nil,
                        durationMs: nil,
                        payloadJson: nil
                    )
                    try record.insert(db)
                }
            }
        }

        try database.purge(keepingSessions: 10)

        let remaining = try database.pool.read {
            try String.fetchAll($0, sql: "SELECT DISTINCT session_id FROM events ORDER BY session_id")
        }
        #expect(remaining == (3...12).map { String(format: "s%02d", $0) })

        let rowCount = try database.pool.read {
            try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM events")
        }
        #expect(rowCount == 10 * 3)
    }

    @Test func exportSnapshotProducesSingleFileCopy() throws {
        let database = try makeTemporaryDatabase()
        try database.pool.write { db in
            let record = EventRecord(
                sessionId: "session-1",
                sessionSequence: 1,
                timestamp: Date(timeIntervalSince1970: 1_751_700_000),
                eventKind: "ui",
                identifier: "screen_viewed_home",
                httpMethod: nil,
                url: nil,
                statusCode: nil,
                durationMs: nil,
                payloadJson: nil
            )
            try record.insert(db)
        }

        let url = try database.exportSnapshot()
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(!FileManager.default.fileExists(atPath: url.path + "-wal"))
        #expect(!FileManager.default.fileExists(atPath: url.path + "-shm"))

        var configuration = Configuration()
        configuration.readonly = true
        let exported = try DatabaseQueue(path: url.path, configuration: configuration)
        let count = try exported.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM events") }
        let version = try exported.read { try Int.fetchOne($0, sql: "PRAGMA user_version") }
        #expect(count == 1)
        #expect(version == TokiwatariDatabase.schemaVersion)
    }

    @Test func mismatchedSchemaVersionDropsAndRecreatesTheDatabase() throws {
        let url = makeTemporaryDatabaseURL()
        try createMismatchedDatabase(at: url)

        let reopened = try TokiwatariDatabase(url: url)
        let rowCount = try reopened.pool.read {
            try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM events")
        }
        let version = try reopened.pool.read {
            try Int.fetchOne($0, sql: "PRAGMA user_version")
        }
        #expect(rowCount == 0)
        #expect(version == TokiwatariDatabase.schemaVersion)
    }

    @Test func mismatchedSchemaVersionIsNotRestampedWhenDeletionFails() throws {
        let url = makeTemporaryDatabaseURL()
        defer { try? TokiwatariDatabase.removeDatabaseFiles(at: url) }
        try createMismatchedDatabase(at: url)

        struct RemovalDenied: Error {}
        #expect(throws: RemovalDenied.self) {
            _ = try TokiwatariDatabase(
                url: url,
                removeItemForTesting: { _ in throw RemovalDenied() }
            )
        }

        var configuration = Configuration()
        configuration.readonly = true
        let unchanged = try DatabaseQueue(path: url.path, configuration: configuration)
        let snapshot = try unchanged.read { db in
            (
                count: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM events"),
                version: try Int.fetchOne(db, sql: "PRAGMA user_version")
            )
        }
        try unchanged.close()

        #expect(snapshot.count == 1)
        #expect(snapshot.version == 999)
    }
}
