#if DEBUG
import Foundation
import GRDB
import Testing
@testable import Tokiwatari

@Suite struct BoundedDatabaseTests {

    private func makeEventRecord(
        sessionId: String,
        sequence: Int64,
        payload: String?
    ) -> EventRecord {
        EventRecord(
            sessionId: sessionId,
            sessionSequence: sequence,
            timestamp: Date(timeIntervalSince1970: 1_700_000_000 + Double(sequence)),
            eventKind: "ui",
            identifier: "event_\(sequence)",
            httpMethod: nil,
            url: nil,
            statusCode: nil,
            durationMs: nil,
            payloadJson: payload
        )
    }

    /// Inserts 8KB events until the database reports SQLITE_FULL; returns the
    /// last successfully inserted sequence.
    private func fillToCapacity(_ database: TokiwatariDatabase, sessionId: String) throws -> Int64 {
        let payload = String(repeating: "x", count: 8 * 1024)
        var sequence: Int64 = 0
        while true {
            let record = makeEventRecord(sessionId: sessionId, sequence: sequence + 1, payload: payload)
            do {
                try database.pool.write { db in try record.insert(db) }
                sequence += 1
            } catch let error as DatabaseError where error.resultCode == .SQLITE_FULL {
                return sequence
            }
        }
    }

    @Test func appliesRequestedPageAndJournalLimits() throws {
        let requestedBytes = 2 * 1024 * 1024
        let database = try TokiwatariDatabase(
            url: makeTemporaryDatabaseURL(),
            maximumMainDatabaseSizeBytes: requestedBytes,
            maximumRetainedWALSizeBytes: 2 * 1024 * 1024
        )
        let pageSize = try #require(try database.pool.read {
            try Int64.fetchOne($0, sql: "PRAGMA page_size")
        })
        #expect(database.effectiveMaxPageCount == Int64(requestedBytes) / pageSize)
        #expect(database.effectiveJournalSizeLimit == 2 * 1024 * 1024)
    }

    @Test func clampsUndersizedLimitsToTheMinimums() throws {
        let database = try TokiwatariDatabase(
            url: makeTemporaryDatabaseURL(),
            maximumMainDatabaseSizeBytes: 1,
            maximumRetainedWALSizeBytes: 1
        )
        let pageSize = try #require(try database.pool.read {
            try Int64.fetchOne($0, sql: "PRAGMA page_size")
        })
        #expect(database.effectiveMaxPageCount == Int64(TokiwatariDatabase.minimumMainDatabaseSizeBytes) / pageSize)
        #expect(database.effectiveJournalSizeLimit == Int64(TokiwatariDatabase.minimumRetainedWALSizeBytes))
        #expect(database.maximumRetainedWALSizeBytes == TokiwatariDatabase.minimumRetainedWALSizeBytes)
    }

    @Test func existingLargerDatabaseKeepsItsCurrentPageCountAsTheEffectiveLimit() throws {
        let url = makeTemporaryDatabaseURL()
        do {
            let database = try TokiwatariDatabase(url: url)
            _ = try {
                let payload = String(repeating: "x", count: 8 * 1024)
                for sequence in 1...300 {
                    let record = makeEventRecord(sessionId: "big", sequence: Int64(sequence), payload: payload)
                    try database.pool.write { db in try record.insert(db) }
                }
            }()
            database.checkpointTruncate()
            try database.pool.close()
        }

        let reopened = try TokiwatariDatabase(
            url: url,
            maximumMainDatabaseSizeBytes: 1, // clamped to the 1MB minimum, still below the ~2.4MB DB
            maximumRetainedWALSizeBytes: 1
        )
        let pageSize = try #require(try reopened.pool.read {
            try Int64.fetchOne($0, sql: "PRAGMA page_size")
        })
        let currentPageCount = try #require(try reopened.pool.read {
            try Int64.fetchOne($0, sql: "PRAGMA page_count")
        })
        let requestedPageCount = Int64(TokiwatariDatabase.minimumMainDatabaseSizeBytes) / pageSize
        #expect(currentPageCount > requestedPageCount)
        #expect(reopened.effectiveMaxPageCount > requestedPageCount)
        #expect(reopened.effectiveMaxPageCount >= currentPageCount)

        // Purge frees pages into the freelist; inserts keep working without
        // the file shrinking below the effective limit.
        try reopened.purge(keepingSessions: 0)
        try reopened.pool.write { db in
            try makeEventRecord(sessionId: "after", sequence: 1, payload: "{}").insert(db)
        }
    }

    @Test func effectiveLimitDoesNotRatchetAcrossReopens() throws {
        let url = makeTemporaryDatabaseURL()
        var limits: [Int64] = []
        for round in 0..<3 {
            let database = try TokiwatariDatabase(
                url: url,
                maximumMainDatabaseSizeBytes: 1, // clamped to the 1MB minimum
                maximumRetainedWALSizeBytes: 1
            )
            if round == 0 {
                #expect(try fillToCapacity(database, sessionId: "fill") > 0)
            }
            limits.append(database.effectiveMaxPageCount)
            database.checkpointTruncate()
            try database.pool.close()
        }
        // The first reopen may absorb one page for GRDB's WAL-creating probe;
        // after that the cap must stay put instead of ratcheting per reopen.
        #expect(limits[1] <= limits[0] + 1)
        #expect(limits[2] == limits[1])
    }
}
#endif
