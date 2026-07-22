#if DEBUG
import Foundation
import GRDB

/// Owns the `tokiwatari_debug_events.sqlite` database (WAL mode).
final class TokiwatariDatabase: Sendable {
    /// Bump on every schema change, in lockstep with the CLI's expected version.
    static let schemaVersion = 1

    let pool: DatabasePool

    static let databaseFileName = "tokiwatari_debug_events.sqlite"

    static func defaultDatabaseURL() throws -> URL {
        try supportDirectoryURL()
            .appendingPathComponent("Tokiwatari", isDirectory: true)
            .appendingPathComponent(databaseFileName)
    }

    private static func supportDirectoryURL() throws -> URL {
        try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
    }

    /// 0.3.x and earlier stored the database directly in Application Support.
    /// 0.4.0 deletes those files instead of migrating them (breaking change,
    /// no data migration).
    static func removeLegacyDatabase() throws {
        try removeLegacyDatabase(in: supportDirectoryURL())
    }

    /// Deletes the weakly-redacted 0.3.x database or propagates failure.
    static func removeLegacyDatabase(in supportDirectory: URL) throws {
        try removeDatabaseFiles(at: supportDirectory.appendingPathComponent(databaseFileName))
    }

    enum StorageResetError: Error {
        case fileStillExists(path: String)
    }

    static let defaultRemoveItem: @Sendable (String) throws -> Void = {
        try FileManager.default.removeItem(atPath: $0)
    }

    /// Removes a database and its sidecars, verifying that each is absent.
    static func removeDatabaseFiles(
        at url: URL,
        removeItem: (String) throws -> Void = defaultRemoveItem
    ) throws {
        for suffix in ["", "-wal", "-shm"] {
            let path = url.path + suffix
            do {
                try removeItem(path)
            } catch let error as CocoaError where error.code == .fileNoSuchFile {
                // Already absent.
            }
            guard !FileManager.default.fileExists(atPath: path) else {
                throw StorageResetError.fileStillExists(path: path)
            }
        }
    }

    /// The protection level and backup exclusion are part of the storage
    /// contract (README) — when they cannot be applied and verified, the
    /// caller fails instead of logging into an unprotected file.
    enum StorageProtectionError: Error {
        case fileProtectionNotApplied(fileName: String)
        case backupExclusionNotApplied(fileName: String)
    }

    /// `createDirectory`'s attributes argument has no effect on pre-existing
    /// directories, so protection and backup exclusion are re-applied on every
    /// open (file operations can also reset the backup-exclusion flag).
    static func prepareDirectory(_ directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try applyFileProtection(to: directory)
        try excludeFromBackup(directory)
    }

    /// `.complete` is intentionally not used: it would break WAL checkpoints
    /// and background writes while the device is locked. Applied values are
    /// read back — a silently missing protection class must not pass. The
    /// Simulator never reports protection attributes back, so enforcement is
    /// device-only (the threat model — data at rest on a lost device — does
    /// not apply to Simulator files on a Mac).
    static func applyFileProtection(to url: URL) throws {
        #if os(iOS) && !targetEnvironment(simulator)
        try FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: url.path
        )
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attributes[.protectionKey] as? FileProtectionType == .completeUntilFirstUserAuthentication else {
            throw StorageProtectionError.fileProtectionNotApplied(fileName: url.lastPathComponent)
        }
        #endif
    }

    /// Backup exclusion is what keeps debug logs out of iCloud/iTunes backups
    /// — a silent failure would move data off the device, so the flag is
    /// verified by reading it back on a fresh URL.
    static func excludeFromBackup(_ url: URL) throws {
        var url = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try url.setResourceValues(values)
        let verified = try URL(fileURLWithPath: url.path)
            .resourceValues(forKeys: [.isExcludedFromBackupKey])
        guard verified.isExcludedFromBackup == true else {
            throw StorageProtectionError.backupExclusionNotApplied(fileName: url.lastPathComponent)
        }
    }

    private static func applyStorageAttributes(toDatabaseAt url: URL) throws {
        for suffix in ["", "-wal", "-shm"] {
            let fileURL = URL(fileURLWithPath: url.path + suffix)
            guard FileManager.default.fileExists(atPath: fileURL.path) else { continue }
            try applyFileProtection(to: fileURL)
            try excludeFromBackup(fileURL)
        }
    }

    init(url: URL) throws {
        try Self.prepareDirectory(url.deletingLastPathComponent())

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

        // Apply and verify the real file attributes after open; failure
        // propagates and leaves the SDK inactive rather than logging into
        // unprotected files.
        try Self.applyStorageAttributes(toDatabaseAt: url)
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
