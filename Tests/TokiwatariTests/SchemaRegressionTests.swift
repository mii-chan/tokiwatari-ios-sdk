import Foundation
import GRDB
import Testing
@testable import Tokiwatari

@Suite struct SchemaRegressionTests {

    @Test func schemaVersionIsStillOne() {
        #expect(TokiwatariDatabase.schemaVersion == 1)
    }

    @Test func eventsTableDDLIsUnchanged() throws {
        let database = try makeTemporaryDatabase()
        let tableSQL = try database.pool.read { db in
            try String.fetchOne(
                db,
                sql: "SELECT sql FROM sqlite_master WHERE type = 'table' AND name = 'events'"
            )
        }
        let normalized = tableSQL?
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        #expect(normalized == """
            CREATE TABLE events ( session_id TEXT NOT NULL, session_sequence INTEGER NOT NULL, \
            timestamp TEXT NOT NULL, event_kind TEXT NOT NULL, identifier TEXT, http_method TEXT, \
            url TEXT, status_code INTEGER, duration_ms INTEGER, payload_json TEXT, \
            PRIMARY KEY (session_id, session_sequence) )
            """)

        let indexes = try database.pool.read { db in
            try String.fetchAll(
                db,
                sql: "SELECT name FROM sqlite_master WHERE type = 'index' AND tbl_name = 'events' AND name NOT LIKE 'sqlite_%' ORDER BY name"
            )
        }
        #expect(indexes == ["idx_events_identifier", "idx_events_kind", "idx_events_time"])
    }
}
