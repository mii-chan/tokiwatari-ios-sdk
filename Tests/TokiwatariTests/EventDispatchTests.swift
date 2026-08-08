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
            let done = Mutex(false)
            let loggerCount = 2
            let finished = DispatchSemaphore(value: 0)
            for _ in 0..<loggerCount {
                DispatchQueue.global().async {
                    while !done.withLock({ $0 }) {
                        Tokiwatari.log(identifier: "spin", parameters: ["k": "v"])
                    }
                    finished.signal()
                }
            }
            for (index, url) in urls.enumerated() {
                Tokiwatari.configure(session: CountingSession(id: "gen-\(index)"), databaseURL: url)
                for _ in 0..<100 {
                    Tokiwatari.logAPIEvent(request: makeRequest(), start: Date(), end: Date())
                }
            }
            done.withLock { $0 = true }
            for _ in 0..<loggerCount { finished.wait() }
            try Tokiwatari.databaseForTesting?.flushPendingWrites()

            for (index, url) in urls.enumerated() {
                let sessionIds = try read(url) { db in
                    try String.fetchAll(db, sql: "SELECT DISTINCT session_id FROM events")
                }
                #expect(!sessionIds.isEmpty)
                #expect(
                    sessionIds.allSatisfy { $0 == "gen-\(index)" },
                    "database \(index) contains sessions \(sessionIds)"
                )
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
