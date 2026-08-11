#if DEBUG
import Foundation
import GRDB
import Testing
@testable import Tokiwatari

@Suite(.serialized) struct EventDispatchTests {

    // Wait briefly for transient locks held by the SDK's asynchronous writer.
    private func read<T>(_ url: URL, _ body: (Database) throws -> T) throws -> T {
        var configuration = Configuration()
        configuration.readonly = true
        configuration.busyMode = .timeout(5)
        return try DatabaseQueue(path: url.path, configuration: configuration).read(body)
    }

    @Test func reconfigureRoutesEventsToTheirOwnDatabaseAndSession() throws {
        try tokiwatariGlobalStateLock.withLock { _ in
            let urls = [makeTemporaryDatabaseURL(), makeTemporaryDatabaseURL()]
            for (index, url) in urls.enumerated() {
                Tokiwatari.configure(session: CountingSession(id: "gen-\(index)"), databaseURL: url)
                Tokiwatari.log(identifier: "event")
                Tokiwatari.logAPIEvent(request: makeRequest(), start: Date(), end: Date())
                try Tokiwatari.databaseForTesting?.flushPendingWrites()
            }
            for (index, url) in urls.enumerated() {
                let rows = try read(url) { db in
                    try Row.fetchAll(
                        db,
                        sql: "SELECT session_id, session_sequence FROM events ORDER BY session_sequence"
                    )
                }
                #expect(rows.map { $0["session_id"] as String } == ["gen-\(index)", "gen-\(index)"])
                #expect(rows.map { $0["session_sequence"] as Int64 } == [1, 2])
            }
        }
    }

    @Test func concurrentReconfigureNeverMixesSessionsAcrossDatabases() throws {
        try tokiwatariGlobalStateLock.withLock { _ in
            let urls = (0..<4).map { _ in makeTemporaryDatabaseURL() }
            let loggerCount = 2
            // Split bounded logger bursts across reconfiguration boundaries.
            let logsPerGeneration = 8
            let startGeneration = (0..<loggerCount).map { _ in DispatchSemaphore(value: 0) }
            let continueGeneration = (0..<loggerCount).map { _ in DispatchSemaphore(value: 0) }
            let generationStarted = DispatchSemaphore(value: 0)
            let finished = DispatchSemaphore(value: 0)
            for logger in 0..<loggerCount {
                Thread.detachNewThread {
                    for _ in urls.indices {
                        startGeneration[logger].wait()
                        Tokiwatari.log(identifier: "spin", parameters: ["k": "v"])
                        generationStarted.signal()
                        continueGeneration[logger].wait()
                        for _ in 1..<logsPerGeneration {
                            Tokiwatari.log(identifier: "spin", parameters: ["k": "v"])
                        }
                    }
                    finished.signal()
                }
            }
            var databases: [TokiwatariDatabase] = []
            for (index, url) in urls.enumerated() {
                Tokiwatari.configure(session: CountingSession(id: "gen-\(index)"), databaseURL: url)
                databases.append(try #require(Tokiwatari.databaseForTesting))
                for gate in startGeneration { gate.signal() }
                for _ in 0..<loggerCount { generationStarted.wait() }
                for gate in continueGeneration { gate.signal() }
            }
            for _ in 0..<loggerCount { finished.wait() }
            for database in databases { try database.flushPendingWrites() }

            for (index, url) in urls.enumerated() {
                let (sessionIds, spinEvents) = try read(url) { db in
                    (try String.fetchAll(db, sql: "SELECT DISTINCT session_id FROM events"),
                     try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM events WHERE identifier = 'spin'") ?? 0)
                }
                #expect(!sessionIds.isEmpty)
                #expect(
                    sessionIds.allSatisfy { $0 == "gen-\(index)" },
                    "database \(index) contains sessions \(sessionIds)"
                )
                #expect(spinEvents > 0, "database \(index) contains no concurrent logger events")
            }
        }
    }

    @Test func reconfigureAppliesTheNewSanitizationConfigurationToSubsequentEvents() throws {
        try tokiwatariGlobalStateLock.withLock { _ in
            let first = makeTemporaryDatabaseURL()
            Tokiwatari.configure(session: CountingSession(), databaseURL: first)
            Tokiwatari.log(identifier: "before", parameters: ["teaKey": "kept"])
            try Tokiwatari.databaseForTesting?.flushPendingWrites()

            let second = makeTemporaryDatabaseURL()
            Tokiwatari.configure(
                session: CountingSession(),
                additionalSensitiveBodyKeys: ["teaKey"],
                databaseURL: second
            )
            Tokiwatari.log(identifier: "after", parameters: ["teaKey": "secret"])
            try Tokiwatari.databaseForTesting?.flushPendingWrites()

            let firstPayload = try read(first) { db in
                try String.fetchOne(db, sql: "SELECT payload_json FROM events")
            }
            #expect(firstPayload?.contains("kept") == true)
            let secondPayload = try read(second) { db in
                try String.fetchOne(db, sql: "SELECT payload_json FROM events")
            }
            #expect(secondPayload?.contains("secret") != true)
            #expect(secondPayload?.contains("<redacted>") == true)
        }
    }
}
#endif
