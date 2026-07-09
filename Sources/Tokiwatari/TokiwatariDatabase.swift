#if DEBUG
import Foundation
import GRDB

/// Owns the `tokiwatari_debug_events.sqlite` database (WAL mode).
final class TokiwatariDatabase: Sendable {
    /// Bump on every schema change, in lockstep with the CLI's expected version.
    static let schemaVersion = 1

    let pool: DatabasePool

    static func defaultDatabaseURL() throws -> URL {
        let supportDirectory = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return supportDirectory.appendingPathComponent("tokiwatari_debug_events.sqlite")
    }

    init(url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        var configuration = Configuration()
        configuration.prepareDatabase { db in
            try db.execute(sql: "PRAGMA synchronous = NORMAL")
        }
        // DatabasePool activates WAL journal mode automatically.
        var pool = try DatabasePool(path: url.path, configuration: configuration)

        // On ANY user_version mismatch — upgrade or downgrade — drop the whole
        // database and recreate it. Debug logs are disposable; no migrations.
        let found = try pool.read { db in
            (version: try Int.fetchOne(db, sql: "PRAGMA user_version") ?? 0,
             hasEventsTable: try db.tableExists("events"))
        }
        let isFreshDatabase = found.version == 0 && !found.hasEventsTable
        if !isFreshDatabase && found.version != Self.schemaVersion {
            try pool.close()
            for suffix in ["", "-wal", "-shm"] {
                try? FileManager.default.removeItem(atPath: url.path + suffix)
            }
            print(
                "Tokiwatari: schema version changed (found \(found.version), expected \(Self.schemaVersion)) — debug log was reset"
            )
            pool = try DatabasePool(path: url.path, configuration: configuration)
        }
        self.pool = pool

        try self.pool.write { db in
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS events (
                  session_id        TEXT    NOT NULL,
                  session_sequence  INTEGER NOT NULL,
                  timestamp         TEXT    NOT NULL,
                  event_kind        TEXT    NOT NULL,
                  identifier        TEXT,
                  http_method      TEXT,
                  url               TEXT,
                  status_code       INTEGER,
                  duration_ms       INTEGER,
                  payload_json      TEXT,
                  PRIMARY KEY (session_id, session_sequence)
                )
                """)
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_events_identifier ON events(identifier)")
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_events_kind ON events(event_kind, session_id)")
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_events_time ON events(session_id, timestamp)")
            try db.execute(sql: "PRAGMA user_version = \(Self.schemaVersion)")
        }
    }

    /// Asynchronous insert on GRDB's serial writer queue (never blocks the caller).
    func insertAsync(_ record: EventRecord) {
        pool.asyncWrite({ db in
            try record.insert(db)
        }, completion: { _, result in
            if case .failure(let error) = result {
                print("Tokiwatari: failed to insert event: \(error)")
            }
        })
    }

    func purge(keepingSessions retentionSessions: Int) throws {
        try pool.write { db in
            try db.execute(
                sql: """
                DELETE FROM events
                WHERE session_id NOT IN (
                  SELECT session_id
                  FROM events
                  GROUP BY session_id
                  ORDER BY MAX(timestamp) DESC
                  LIMIT ?
                )
                """,
                arguments: [max(0, retentionSessions)]
            )
        }
    }

    /// `wal_checkpoint(TRUNCATE)`: keeps the WAL small and device snapshot
    /// pulls consistent.
    func checkpointTruncate() {
        do {
            _ = try pool.writeWithoutTransaction { db in
                try db.checkpoint(.truncate)
            }
        } catch {
            // Checkpoint may fail with SQLITE_BUSY while readers are active; harmless.
        }
    }

    /// Consistent single-file snapshot via `VACUUM INTO` (no `-wal`/`-shm`
    /// sidecars), written to the temporary directory.
    func exportSnapshot(now: Date = Date()) throws -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tokiwatari-export", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("tokiwatari_debug_events-\(formatter.string(from: now)).sqlite")
        try? FileManager.default.removeItem(at: url)
        try pool.writeWithoutTransaction { db in
            // VACUUM INTO cannot run inside a transaction.
            try db.execute(sql: "VACUUM INTO ?", arguments: [url.path])
        }
        return url
    }

    /// Test helper: waits for all enqueued asynchronous writes (the writer
    /// queue is serial, so an empty barrier write suffices).
    func flushPendingWrites() throws {
        try pool.write { _ in }
    }
}
#endif
