import Foundation
import Testing
@testable import Tokiwatari

@Suite(.serialized) struct SignpostEmissionTests {

    private func configure(
        outputs: TokiwatariOutputs,
        emitter: FakeSignpostEmitter,
        session: any TokiwatariSessionProviding = CountingSession(),
        assertingValidity: Bool = true,
        databaseURL: URL = makeTemporaryDatabaseURL()
    ) {
        Tokiwatari.configure(
            session: session,
            outputs: outputs,
            assertingValidity: assertingValidity,
            signpostEmitterForTesting: emitter,
            databaseURL: databaseURL
        )
    }

    // MARK: UI events

    @Test func uiEventEmitsOneCorrelationSignpostWithoutParameters() throws {
        try tokiwatariGlobalStateLock.withLock { _ in
            let emitter = FakeSignpostEmitter()
            configure(outputs: [.signposts], emitter: emitter)
            Tokiwatari.log(identifier: "favorite_button", parameters: ["param_key": "param_secret"])

            let event = try #require(emitter.events.first)
            #expect(emitter.events.count == 1)
            #expect(event.kind == .ui)
            #expect(
                event.message
                    == "v=1 session_id=test-session session_sequence=1 identifier=favorite_button end=1"
            )
            #expect(!event.message.contains("param_key"))
            #expect(!event.message.contains("param_secret"))
        }
    }

    @Test func uiSignpostIdentifiersAreSanitized() throws {
        try tokiwatariGlobalStateLock.withLock { _ in
            let emitter = FakeSignpostEmitter()
            configure(outputs: [.signposts], emitter: emitter)
            Tokiwatari.log(identifier: "tap\u{0007}done")

            let message = try #require(emitter.events.first?.message)
            let parsed = try #require(SignpostMetadataCodec.strictlyParsed(message, kind: .ui))
            #expect(parsed.optionalFields?.identifier == "tap\u{FFFD}done")
        }
    }

    // MARK: API events

    @Test func apiEventEmitsOneBoundedCompletionSignpost() throws {
        try tokiwatariGlobalStateLock.withLock { _ in
            let emitter = FakeSignpostEmitter()
            configure(outputs: [.signposts], emitter: emitter)

            let start = Date(timeIntervalSince1970: 1000)
            Tokiwatari.logAPIEvent(
                identifier: "toggleFavorite",
                request: makeRequest(
                    "https://api.tokiwatari.test/v1/teas?token=sekrit",
                    method: "POST",
                    headers: ["Authorization": "Bearer sekrit-token"],
                    body: Data(#"{"password":"hunter2"}"#.utf8),
                    contentType: "application/json"
                ),
                response: makeResponse(statusCode: 201, headers: ["Set-Cookie": "cookie-secret"]),
                responseBody: Data(#"{"body_field":"body-secret"}"#.utf8),
                error: NSError(domain: "TeaErrorDomain", code: 42),
                start: start,
                end: start.addingTimeInterval(0.087)
            )

            let event = try #require(emitter.events.first)
            #expect(emitter.events.count == 1)
            #expect(event.kind == .api)
            #expect(
                event.message
                    == "v=1 session_id=test-session session_sequence=1 method=POST status=201 duration_ms=87 identifier=toggleFavorite end=1"
            )
            for forbidden in [
                "tokiwatari.test", "sekrit", "Authorization", "hunter2",
                "cookie-secret", "body-secret", "TeaErrorDomain",
            ] {
                #expect(!event.message.contains(forbidden), "leaked \(forbidden)")
            }
        }
    }

    @Test func apiSignpostOmitsAbsentOptionalFields() throws {
        try tokiwatariGlobalStateLock.withLock { _ in
            let emitter = FakeSignpostEmitter()
            configure(outputs: [.signposts], emitter: emitter)
            Tokiwatari.logAPIEvent(
                request: makeRequest(),
                start: Date(),
                end: Date()
            )

            let message = try #require(emitter.events.first?.message)
            let parsed = try #require(SignpostMetadataCodec.strictlyParsed(message, kind: .api))
            #expect(parsed.optionalFields?.method == "GET")
            #expect(parsed.optionalFields?.status == nil)
            #expect(parsed.optionalFields?.identifier == nil)
            #expect(parsed.optionalFields?.durationMs == 0)
        }
    }

    // MARK: Dual output correlation

    @Test func dualOutputConsumesOneSequencePerEventAndMatchesTheRow() throws {
        let emitter = FakeSignpostEmitter()
        let events = try recordedEvents(outputs: [.storage, .signposts], signpostEmitter: emitter) {
            Tokiwatari.log(identifier: "first_ui")
            Tokiwatari.logAPIEvent(request: makeRequest(), start: Date(), end: Date())
        }

        #expect(events.count == 2)
        #expect(emitter.events.count == 2)
        let parsedMessages = try emitter.events.map { event in
            try #require(SignpostMetadataCodec.parsed(
                event.message,
                kind: event.kind == .ui ? .ui : .api
            ))
        }
        for (row, parsed) in zip(events, parsedMessages) {
            #expect(parsed.sessionId == row.sessionId)
            #expect(parsed.sessionSequence == row.sessionSequence)
        }
        #expect(parsedMessages.map(\.sessionSequence) == [1, 2])
    }

    // MARK: Signposts-only sequences

    @Test func signpostsOnlySequencesRemainStrictlyIncreasing() throws {
        try tokiwatariGlobalStateLock.withLock { _ in
            let emitter = FakeSignpostEmitter()
            configure(outputs: [.signposts], emitter: emitter)
            for _ in 0..<5 {
                Tokiwatari.log(identifier: "spin")
            }
            let sequences = try emitter.events.map { event in
                try #require(SignpostMetadataCodec.parsed(event.message, kind: .ui)).sessionSequence
            }
            #expect(sequences == [1, 2, 3, 4, 5])
        }
    }

    @Test func concurrentSignpostsOnlyLoggingKeepsSequencesUnique() throws {
        try tokiwatariGlobalStateLock.withLock { _ in
            let emitter = FakeSignpostEmitter()
            configure(outputs: [.signposts], emitter: emitter)
            let threads = 4
            let perThread = 250
            DispatchQueue.concurrentPerform(iterations: threads) { _ in
                for _ in 0..<perThread {
                    Tokiwatari.log(identifier: "spin")
                }
            }
            let sequences = try emitter.events.map { event in
                try #require(SignpostMetadataCodec.parsed(event.message, kind: .ui)).sessionSequence
            }
            #expect(sequences.count == threads * perThread)
            #expect(Set(sequences).count == sequences.count)
            #expect(sequences.min() == 1)
            #expect(sequences.max() == Int64(threads * perThread))
        }
    }

    @Test func zeroAndNegativeCustomSequencesAreAccepted() throws {
        try tokiwatariGlobalStateLock.withLock { _ in
            final class NegativeStartSession: TokiwatariSessionProviding {
                private let state = Mutex<Int64>(-3)
                func next() -> (sessionId: String, sequence: Int64) {
                    state.withLock { s in
                        s += 1
                        return ("negative-session", s)
                    }
                }
                var currentId: String { "negative-session" }
            }
            let emitter = FakeSignpostEmitter()
            configure(outputs: [.signposts], emitter: emitter, session: NegativeStartSession())
            for _ in 0..<3 {
                Tokiwatari.log(identifier: "early")
            }
            let sequences = try emitter.events.map { event in
                try #require(SignpostMetadataCodec.parsed(event.message, kind: .ui)).sessionSequence
            }
            #expect(sequences == [-2, -1, 0])
        }
    }

    // MARK: Fast path

    @Test func disabledEmitterConsumesNoSequenceAndEmitsNothing() throws {
        try tokiwatariGlobalStateLock.withLock { _ in
            let emitter = FakeSignpostEmitter(enabled: false)
            configure(outputs: [.signposts], emitter: emitter)
            #expect(Tokiwatari.isActive)

            Tokiwatari.log(identifier: "dropped")
            Tokiwatari.logAPIEvent(request: makeRequest(), start: Date(), end: Date())
            #expect(emitter.events.isEmpty)

            emitter.setEnabled(true)
            Tokiwatari.log(identifier: "first")
            let message = try #require(emitter.events.first?.message)
            let parsed = try #require(SignpostMetadataCodec.parsed(message, kind: .ui))
            #expect(parsed.sessionSequence == 1)
        }
    }

    @Test func disabledEmitterStillStoresRowsWhenStorageIsActive() throws {
        let emitter = FakeSignpostEmitter(enabled: false)
        let events = try recordedEvents(outputs: [.storage, .signposts], signpostEmitter: emitter) {
            Tokiwatari.log(identifier: "stored_only")
        }
        #expect(events.count == 1)
        #expect(emitter.events.isEmpty)
    }

    // MARK: Session ID contract

    @Test func invalidSessionIdsDropTheEventFromEverySink() throws {
        try tokiwatariGlobalStateLock.withLock { _ in
            final class FixedIdSession: TokiwatariSessionProviding {
                let id: String
                private let state = Mutex<Int64>(0)
                init(id: String) { self.id = id }
                func next() -> (sessionId: String, sequence: Int64) {
                    state.withLock { s in
                        s += 1
                        return (id, s)
                    }
                }
                var currentId: String { id }
            }

            for invalidId in ["", String(repeating: "s", count: 129), String(repeating: "茶", count: 43)] {
                let emitter = FakeSignpostEmitter()
                let url = makeTemporaryDatabaseURL()
                configure(
                    outputs: [.storage, .signposts],
                    emitter: emitter,
                    session: FixedIdSession(id: invalidId),
                    assertingValidity: false,
                    databaseURL: url
                )
                Tokiwatari.log(identifier: "dropped")
                Tokiwatari.logAPIEvent(request: makeRequest(), start: Date(), end: Date())
                try Tokiwatari.databaseForTesting?.flushPendingWrites()
                #expect(emitter.events.isEmpty, "id of \(invalidId.utf8.count) bytes must drop")
                let rows = try Tokiwatari.databaseForTesting?.pool.read { db in
                    try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM events")
                }
                #expect(rows == 0)
            }

            let emitter = FakeSignpostEmitter()
            configure(
                outputs: [.signposts],
                emitter: emitter,
                session: FixedIdSession(id: String(repeating: "s", count: 128))
            )
            Tokiwatari.log(identifier: "kept")
            #expect(emitter.events.count == 1)
        }
    }

    // MARK: Trace contract

    @Test func signpostTraceContractIsFixed() {
        #expect(TokiwatariSignposter.subsystem == "com.tokiwatari")
        #expect(TokiwatariSignposter.category == "events")
        #expect("\(TokiwatariSignposter.uiEventName)" == "TokiwatariUI")
        #expect("\(TokiwatariSignposter.apiEventName)" == "TokiwatariAPI")
    }
}
