import Foundation
import GRDB

/// Owns the `tokiwatari_debug_events.sqlite` database (WAL mode).
final class TokiwatariDatabase: Sendable {
    /// Bump on every schema change, in lockstep with the CLI's expected version.
    static let schemaVersion = 1

    let pool: DatabasePool
    let maximumRetainedWALSizeBytes: Int
    /// Actual limits reported back by SQLite — an existing database larger
    /// than the requested cap raises `max_page_count` to its current size.
    let effectiveMaxPageCount: Int64
    let effectiveJournalSizeLimit: Int64

    static let databaseFileName = "tokiwatari_debug_events.sqlite"
    static let minimumMainDatabaseSizeBytes = 1024 * 1024
    static let minimumRetainedWALSizeBytes = 256 * 1024
    /// Transient page allowance for opening a full database; withdrawn at the
    /// end of `init` so reopening cannot ratchet the cap up.
    static let openingPageHeadroom: Int64 = 16

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

    init(
        url: URL,
        maximumMainDatabaseSizeBytes: Int = 128 * 1024 * 1024,
        maximumRetainedWALSizeBytes: Int = 16 * 1024 * 1024,
        removeItemForTesting: ((String) throws -> Void)? = nil
    ) throws {
        assert(
            maximumMainDatabaseSizeBytes > 0 && maximumRetainedWALSizeBytes > 0,
            "Tokiwatari: database size limits must be positive"
        )
        // Clamp BEFORE any PRAGMA runs; a non-positive journal_size_limit
        // would mean "unlimited".
        let databaseLimit = Int64(max(Self.minimumMainDatabaseSizeBytes, maximumMainDatabaseSizeBytes))
        let walLimit = Int64(max(Self.minimumRetainedWALSizeBytes, maximumRetainedWALSizeBytes))
        self.maximumRetainedWALSizeBytes = Int(walLimit)

        try Self.prepareDirectory(url.deletingLastPathComponent())

        var configuration = Configuration()
        configuration.prepareDatabase { db in
            try db.execute(sql: "PRAGMA synchronous = NORMAL")
            // DatabasePool runs this for readers too; size pragmas are writer-only.
            guard !db.configuration.readonly else { return }
            let pageSize = try Int64.fetchOne(db, sql: "PRAGMA page_size") ?? 4096
            let currentPageCount = try Int64.fetchOne(db, sql: "PRAGMA page_count") ?? 0
            let requestedPageCount = max(1, databaseLimit / pageSize)
            // Transient opening headroom: pool bootstrap must be able to
            // allocate a page even on a full database (GRDB's WAL-creating
            // `grdb_issue_102` probe). The steady-state cap is re-applied
            // WITHOUT headroom at the end of `init`.
            let appliedPageCount = max(requestedPageCount, currentPageCount + Self.openingPageHeadroom)
            // No placeholders for these pragmas — interpolate validated integers only.
            _ = try Int64.fetchOne(db, sql: "PRAGMA max_page_count = \(appliedPageCount)")
            _ = try Int64.fetchOne(db, sql: "PRAGMA journal_size_limit = \(walLimit)")
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
            // Never re-stamp a surviving database with the current version.
            try Self.removeDatabaseFiles(at: url, removeItem: removeItemForTesting ?? Self.defaultRemoveItem)
            pool = try DatabasePool(path: url.path, configuration: configuration)
            print(
                "Tokiwatari: schema version changed (found \(found.version), expected \(Self.schemaVersion)) — debug log was reset"
            )
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

        // Withdraw the opening headroom and verify the effective values on
        // the writer: the steady-state cap is the requested size, or the
        // database's current size if that is already larger — never more.
        // SQLite itself never lets max_page_count drop below the current page
        // count, so an over-cap database keeps its pages and simply cannot
        // grow. The writer connection is permanent, so the value sticks.
        let effective = try pool.write { db in
            let pageSize = try Int64.fetchOne(db, sql: "PRAGMA page_size") ?? 4096
            let currentPageCount = try Int64.fetchOne(db, sql: "PRAGMA page_count") ?? 0
            let steadyPageCount = max(max(1, databaseLimit / pageSize), currentPageCount)
            _ = try Int64.fetchOne(db, sql: "PRAGMA max_page_count = \(steadyPageCount)")
            return (pageCount: try Int64.fetchOne(db, sql: "PRAGMA max_page_count") ?? 0,
                    journalLimit: try Int64.fetchOne(db, sql: "PRAGMA journal_size_limit") ?? 0)
        }
        self.effectiveMaxPageCount = effective.pageCount
        self.effectiveJournalSizeLimit = effective.journalLimit

        // Apply and verify the real file attributes after open; failure
        // propagates and leaves the SDK inactive rather than logging into
        // unprotected files.
        try Self.applyStorageAttributes(toDatabaseAt: url)
    }

    static let fullRecoveryChunkSize = 200
    static let fullRecoveryPreservedTail = 50

    /// Asynchronous insert on GRDB's serial writer queue (never blocks the
    /// caller). SQLITE_FULL — which can also mean real disk exhaustion — is
    /// handled with a bounded retry: each purge runs in a NEW transaction
    /// after the failed insert rolled back, and the final failure drops the
    /// event without ever trying to log the failure into the database.
    func insertAsync(_ record: EventRecord) {
        pool.asyncWriteWithoutTransaction { db in
            var remainingRecoveries: ArraySlice<@Sendable (Database) throws -> Void> = [
                { @Sendable db in try Self.purgeOldestCompletedSession(db, currentSessionId: record.sessionId) },
                { @Sendable db in try Self.purgeOldestEventsOfCurrentSession(db, sessionId: record.sessionId) },
            ][...]
            while true {
                do {
                    try db.inTransaction {
                        try record.insert(db)
                        return .commit
                    }
                    return
                } catch let error as DatabaseError where error.resultCode == .SQLITE_FULL {
                    guard let recovery = remainingRecoveries.popFirst() else {
                        print("Tokiwatari: dropped an event after SQLITE_FULL retries")
                        return
                    }
                    do {
                        try db.inTransaction {
                            try recovery(db)
                            return .commit
                        }
                    } catch {
                        // The purge itself can fail when the disk is full.
                    }
                } catch {
                    print("Tokiwatari: failed to insert event: \(error)")
                    return
                }
            }
        }
    }

    private static func purgeOldestCompletedSession(_ db: Database, currentSessionId: String) throws {
        try db.execute(
            sql: """
            DELETE FROM events WHERE session_id = (
              SELECT session_id
              FROM events
              WHERE session_id <> ?
              GROUP BY session_id
              ORDER BY MAX(timestamp) ASC
              LIMIT 1
            )
            """,
            arguments: [currentSessionId]
        )
    }

    /// Chunk purge of the current session's oldest events — never the whole
    /// current session.
    private static func purgeOldestEventsOfCurrentSession(_ db: Database, sessionId: String) throws {
        let count = try Int.fetchOne(
            db,
            sql: "SELECT COUNT(*) FROM events WHERE session_id = ?",
            arguments: [sessionId]
        ) ?? 0
        let deletable = min(fullRecoveryChunkSize, max(0, count - fullRecoveryPreservedTail))
        guard deletable > 0 else { return }
        try db.execute(
            sql: """
            DELETE FROM events
            WHERE session_id = ? AND session_sequence IN (
              SELECT session_sequence FROM events
              WHERE session_id = ?
              ORDER BY session_sequence ASC
              LIMIT ?
            )
            """,
            arguments: [sessionId, sessionId, deletable]
        )
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

    static let passiveCheckpointThresholdBytes = 1024 * 1024

    /// Periodic maintenance (every 30s): retention purge, then WAL-size-gated
    /// checkpoints. PASSIVE runs only when the WAL exists and is at least
    /// `passiveCheckpointThresholdBytes` (it merely assists SQLite's own
    /// ~1000-page auto checkpoint); TRUNCATE runs only when the WAL exceeds
    /// `maximumRetainedWALSizeBytes`. Both are best-effort — busy is normal.
    func performMaintenance(retainingSessions: Int) {
        try? purge(keepingSessions: retainingSessions)
        guard let walSize = walFileSizeBytes() else { return }
        if walSize > maximumRetainedWALSizeBytes {
            checkpointTruncate()
        } else if walSize >= Self.passiveCheckpointThresholdBytes {
            do {
                _ = try pool.writeWithoutTransaction { db in
                    try db.checkpoint(.passive)
                }
            } catch {
                // Busy is a normal state.
            }
        }
    }

    func walFileSizeBytes() -> Int? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: pool.path + "-wal") else {
            return nil
        }
        return (attributes[.size] as? NSNumber)?.intValue
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

    static let exportTimeToLive: TimeInterval = 24 * 60 * 60

    static func exportDirectoryURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("TokiwatariExports", isDirectory: true)
    }

    /// Best-effort deletion of expired exports at the next cleanup opportunity.
    static func cleanUpExpiredExports(now: Date = Date()) {
        let fileManager = FileManager.default
        guard let contents = try? fileManager.contentsOfDirectory(
            at: exportDirectoryURL(),
            includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return }
        for file in contents {
            guard let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate,
                now.timeIntervalSince(modified) >= exportTimeToLive
            else { continue }
            try? fileManager.removeItem(at: file)
        }
    }

    /// Consistent single-file snapshot via `VACUUM INTO` (no `-wal`/`-shm`
    /// sidecars). The directory is protected and backup-excluded BEFORE the
    /// file is generated, so the export inherits protection while still being
    /// written; attributes are re-applied to the finished file.
    func exportSnapshot() throws -> URL {
        // Minimize the WAL before pulling a snapshot from the device.
        checkpointTruncate()
        Self.cleanUpExpiredExports()
        let directory = Self.exportDirectoryURL()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Self.applyFileProtection(to: directory)
        try Self.excludeFromBackup(directory)
        let url = directory.appendingPathComponent("tokiwatari-\(UUID().uuidString).sqlite")
        try pool.writeWithoutTransaction { db in
            // VACUUM INTO cannot run inside a transaction.
            try db.execute(sql: "VACUUM INTO ?", arguments: [url.path])
        }
        do {
            try Self.applyFileProtection(to: url)
            try Self.excludeFromBackup(url)
        } catch {
            // Never hand out an export whose attributes could not be verified.
            try? FileManager.default.removeItem(at: url)
            throw error
        }
        return url
    }

    /// Test helper: waits for all enqueued asynchronous writes (the writer
    /// queue is serial, so an empty barrier write suffices).
    func flushPendingWrites() throws {
        try pool.write { _ in }
    }
}
