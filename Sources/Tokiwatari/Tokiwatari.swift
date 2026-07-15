import Foundation
import Synchronization
#if canImport(UIKit)
import UIKit
#endif

/// Tokiwatari debug logging SDK entry point.
///
/// All logging machinery is compiled only in DEBUG builds. In Release the public
/// API still exists (so app code compiles unchanged) but every call is a no-op.
public enum Tokiwatari {

    public enum ExportError: Error {
        /// `configure` has not been called (or opening the database failed).
        case notConfigured
        case unavailableInRelease
    }

    // MARK: - Public API (exists in all configurations)

    /// Initializes the SDK.
    ///
    /// - Parameters:
    ///   - session: session provider shared by the UI and API loggers.
    ///   - retentionSessions: number of most-recent sessions to keep; all rows
    ///     of older sessions are deleted at configure time.
    ///   - underlyingURLProtocols: `URLProtocol` classes inserted into the
    ///     internal URLSession that performs the actual transfer — the
    ///     mock-injection hook for tests/playgrounds.
    ///   - additionalSensitiveHeaderNames: header names (case-insensitive)
    ///     recorded as `<redacted>`, in addition to the built-in set. Built-ins
    ///     cannot be opted out of.
    ///   - additionalSensitiveBodyKeys: JSON body keys recorded as `<redacted>`,
    ///     in addition to the built-in set; matching ignores case and `_`/`-`
    ///     and recurses into nested values. Built-ins cannot be opted out of.
    public static func configure(
        session: any TokiwatariSessionProviding = TokiwatariLogSession(),
        retentionSessions: Int = 10,
        underlyingURLProtocols: [AnyClass] = [],
        additionalSensitiveHeaderNames: [String] = [],
        additionalSensitiveBodyKeys: [String] = []
    ) {
        #if DEBUG
        configure(
            session: session,
            retentionSessions: retentionSessions,
            underlyingURLProtocols: underlyingURLProtocols,
            additionalSensitiveHeaderNames: additionalSensitiveHeaderNames,
            additionalSensitiveBodyKeys: additionalSensitiveBodyKeys,
            databaseURL: nil
        )
        #else
        print(
            "Tokiwatari: configure() called but logging is compiled out — this package "
                + "was built without DEBUG. Custom build configurations build Swift "
                + "packages in release; all Tokiwatari calls are no-ops."
        )
        #endif
    }

    /// True when logging is compiled in (DEBUG package build) and `configure` has opened the database.
    public static var isActive: Bool {
        #if DEBUG
        isConfigured
        #else
        false
        #endif
    }

    /// Records a UI event on the debug timeline
    /// (`event_kind = 'ui'`, `identifier = logIdentifier`, `payload_json = parameters`).
    public static func log(_ event: any TokiwatariEvent) {
        #if DEBUG
        let payloadJson = jsonString(fromJSONObject: event.parameters)
        guard let slot = nextEventSlot() else { return }
        let record = EventRecord(
            sessionId: slot.sessionId,
            sessionSequence: slot.sequence,
            timestamp: Date(),
            eventKind: "ui",
            identifier: event.logIdentifier,
            httpMethod: nil,
            url: nil,
            statusCode: nil,
            durationMs: nil,
            payloadJson: payloadJson
        )
        slot.database.insertAsync(record)
        #endif
    }

    /// Exports a consistent single-file snapshot of the debug database
    /// (`VACUUM INTO`, no `-wal`/`-shm` sidecars) into the temporary directory
    /// and returns its file URL. Read it with `tokiwatari --db <path>`.
    public static func exportSnapshot() throws -> URL {
        #if DEBUG
        guard let database = state.withLock({ $0.database }) else {
            throw ExportError.notConfigured
        }
        return try database.exportSnapshot()
        #else
        throw ExportError.unavailableInRelease
        #endif
    }

    /// Inserts `TokiwatariURLProtocol` at the front of the configuration's
    /// `protocolClasses`. (`URLSession.shared` is already covered: `configure`
    /// calls `URLProtocol.registerClass`.)
    public static func enableAPILogging(in configuration: URLSessionConfiguration) {
        #if DEBUG
        var protocolClasses = configuration.protocolClasses ?? []
        protocolClasses.removeAll { $0 == TokiwatariURLProtocol.self }
        protocolClasses.insert(TokiwatariURLProtocol.self, at: 0)
        configuration.protocolClasses = protocolClasses
        #endif
    }

    // MARK: - Internal (DEBUG only)

    #if DEBUG
    private struct GlobalState {
        var session: (any TokiwatariSessionProviding)?
        var database: TokiwatariDatabase?
        var underlyingURLProtocols: [AnyClass] = []
        var sensitiveHeaderNames: Set<String> = Tokiwatari.defaultSensitiveHeaderNames
        var sensitiveBodyKeys: Set<String> = Tokiwatari.defaultSensitiveBodyKeys
        // Watermark for the sequence-monotonicity assertion in nextEventSlot().
        var lastSessionId: String?
        var lastSequence: Int64 = 0
    }

    private static let state = Mutex(GlobalState())
    private static let bootstrapped = Mutex(false)
    private static let checkpointTimer = Mutex<(any DispatchSourceTimer)?>(nil)
    private static let checkpointInterval: TimeInterval = 30

    /// Internal configure that allows overriding the database location (tests).
    static func configure(
        session: any TokiwatariSessionProviding,
        retentionSessions: Int,
        underlyingURLProtocols: [AnyClass],
        additionalSensitiveHeaderNames: [String] = [],
        additionalSensitiveBodyKeys: [String] = [],
        databaseURL: URL?
    ) {
        var database: TokiwatariDatabase?
        do {
            let url = try databaseURL ?? TokiwatariDatabase.defaultDatabaseURL()
            let db = try TokiwatariDatabase(url: url)
            try db.purge(keepingSessions: retentionSessions)
            database = db
        } catch {
            assertionFailure("Tokiwatari: failed to open the debug event database: \(error)")
        }
        state.withLock { s in
            s.session = session
            s.database = database
            s.underlyingURLProtocols = underlyingURLProtocols
            s.sensitiveHeaderNames = defaultSensitiveHeaderNames
                .union(additionalSensitiveHeaderNames.map { $0.lowercased() })
            s.sensitiveBodyKeys = defaultSensitiveBodyKeys
                .union(additionalSensitiveBodyKeys.map(normalizedBodyKey))
            s.lastSessionId = nil
            s.lastSequence = 0
        }
        bootstrapIfNeeded()
    }

    private static func bootstrapIfNeeded() {
        let isFirst = bootstrapped.withLock { flag -> Bool in
            if flag { return false }
            flag = true
            return true
        }
        guard isFirst else { return }

        // Makes API logging work for URLSession.shared as well.
        URLProtocol.registerClass(TokiwatariURLProtocol.self)

        // Periodic wal_checkpoint(TRUNCATE): the background-transition hook
        // below never fires while debugging in the foreground.
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + checkpointInterval, repeating: checkpointInterval)
        timer.setEventHandler { Tokiwatari.checkpointDatabase() }
        timer.resume()
        checkpointTimer.withLock { $0 = timer }

        #if canImport(UIKit)
        // The observation intentionally lives for the process lifetime.
        _ = NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: nil
        ) { _ in
            Tokiwatari.checkpointDatabase()
        }
        #endif
    }

    static func checkpointDatabase() {
        let database = state.withLock { $0.database }
        database?.checkpointTruncate()
    }

    static var isConfigured: Bool {
        state.withLock { $0.database != nil }
    }

    static var underlyingURLProtocolsForInnerSession: [AnyClass] {
        state.withLock { $0.underlyingURLProtocols }
    }

    static var databaseForTesting: TokiwatariDatabase? {
        state.withLock { $0.database }
    }

    /// Atomically obtains the next (sessionId, sequence) pair and verifies the
    /// monotonicity contract under the same lock, so concurrent callers cannot
    /// produce false-positive assertion failures. `provider.next()` runs while
    /// holding the SDK lock — it must not call back into Tokiwatari.
    private static func nextEventSlot() -> (sessionId: String, sequence: Int64, database: TokiwatariDatabase)? {
        state.withLock { s -> (sessionId: String, sequence: Int64, database: TokiwatariDatabase)? in
            guard let provider = s.session, let database = s.database else { return nil }
            let (sessionId, sequence) = provider.next()
            if s.lastSessionId == sessionId {
                assert(
                    sequence > s.lastSequence,
                    """
                    Tokiwatari: TokiwatariSessionProviding must return strictly \
                    increasing sequences within a session \
                    (got \(sequence) after \(s.lastSequence) for session \(sessionId)).
                    """
                )
            }
            s.lastSessionId = sessionId
            s.lastSequence = sequence
            return (sessionId, sequence, database)
        }
    }

    // MARK: API event recording (called by TokiwatariURLProtocol)

    static let bodyExcerptByteLimit = 64 * 1024
    static let redactedValue = "<redacted>"
    private static let defaultSensitiveHeaderNames: Set<String> = [
        "authorization",
        "proxy-authorization",
        "www-authenticate",
        "cookie",
        "set-cookie",
        "x-api-key",
        "x-auth-token",
    ]
    // Stored pre-normalized (lowercased, "_"/"-" stripped); see normalizedBodyKey.
    private static let defaultSensitiveBodyKeys: Set<String> = [
        "password",
        "passcode",
        "secret",
        "token",
        "accesstoken",
        "refreshtoken",
        "idtoken",
        "apikey",
        "clientsecret",
        "authorization",
    ]

    static func recordAPIEvent(
        request: URLRequest,
        requestBody: Data?,
        response: HTTPURLResponse?,
        responseBody: Data?,
        error: (any Error)?,
        start: Date,
        end: Date
    ) {
        guard let slot = nextEventSlot() else { return }
        let (sensitiveNames, sensitiveBodyKeys) = state.withLock {
            ($0.sensitiveHeaderNames, $0.sensitiveBodyKeys)
        }

        var payload: [String: Any] = [:]

        var requestInfo: [String: Any] = [:]
        if let headers = request.allHTTPHeaderFields, !headers.isEmpty {
            requestInfo["headers"] = redactedHeaders(headers, sensitiveNames: sensitiveNames)
        }
        if let requestBody {
            let (text, isTruncated) = redactedBodyExcerpt(requestBody, sensitiveKeys: sensitiveBodyKeys)
            requestInfo["body"] = text
            if isTruncated { requestInfo["body_truncated"] = true }
        }
        if !requestInfo.isEmpty { payload["request"] = requestInfo }

        if let response {
            var responseInfo: [String: Any] = [:]
            var headers: [String: String] = [:]
            for (name, value) in response.allHeaderFields {
                if let name = name as? String {
                    headers[name] = "\(value)"
                }
            }
            if !headers.isEmpty { responseInfo["headers"] = redactedHeaders(headers, sensitiveNames: sensitiveNames) }
            if let responseBody {
                let (text, isTruncated) = redactedBodyExcerpt(responseBody, sensitiveKeys: sensitiveBodyKeys)
                responseInfo["body"] = text
                if isTruncated { responseInfo["body_truncated"] = true }
            }
            if !responseInfo.isEmpty { payload["response"] = responseInfo }
        }

        if let error {
            payload["error"] = String(describing: error)
        }

        let record = EventRecord(
            sessionId: slot.sessionId,
            sessionSequence: slot.sequence,
            timestamp: end,
            eventKind: "api",
            identifier: graphQLIdentifier(requestBody: requestBody),
            httpMethod: request.httpMethod,
            url: request.url?.absoluteString,
            statusCode: response?.statusCode,
            durationMs: Int((end.timeIntervalSince(start) * 1000).rounded()),
            payloadJson: payload.isEmpty ? nil : jsonString(fromJSONObject: payload)
        )
        slot.database.insertAsync(record)
    }

    /// Identifier for GraphQL api rows: `GraphQL:<Type>:<Name>`
    /// (`GraphQL:<Type>` for anonymous operations). A request counts as GraphQL
    /// when its body is a JSON object with a string `query` field; every other
    /// api row keeps identifier NULL.
    static func graphQLIdentifier(requestBody: Data?) -> String? {
        guard let requestBody,
              requestBody.first == UInt8(ascii: "{"),
              let object = (try? JSONSerialization.jsonObject(with: requestBody)) as? [String: Any],
              let document = object["query"] as? String
        else { return nil }

        func typeSegment(_ keyword: some StringProtocol) -> String {
            keyword.prefix(1).uppercased() + keyword.dropFirst()
        }
        let definitions = document.matches(of: /\b(query|mutation|subscription)\s+([_A-Za-z][_0-9A-Za-z]*)/)

        if let name = object["operationName"] as? String, !name.isEmpty {
            // Multi-operation documents: operationName picks the one executed.
            let keyword = definitions.first { $0.2 == name }?.1 ?? definitions.first?.1 ?? "query"
            return "GraphQL:\(typeSegment(keyword)):\(name)"
        }
        if let first = definitions.first {
            return "GraphQL:\(typeSegment(first.1)):\(first.2)"
        }
        let trimmed = document.drop(while: \.isWhitespace)
        let keyword = ["mutation", "subscription"].first { trimmed.hasPrefix($0) } ?? "query"
        return "GraphQL:\(typeSegment(keyword))"
    }

    /// `sensitiveNames` must contain lowercased names.
    static func redactedHeaders(
        _ headers: [String: String],
        sensitiveNames: Set<String>
    ) -> [String: String] {
        var result: [String: String] = [:]
        result.reserveCapacity(headers.count)
        for (name, value) in headers {
            result[name] = sensitiveNames.contains(name.lowercased())
                ? redactedValue
                : value
        }
        return result
    }

    /// Key normalization for body redaction: lowercased with `_`/`-` stripped,
    /// so `access_token`, `accessToken` and `ACCESS-TOKEN` all match.
    static func normalizedBodyKey(_ key: some StringProtocol) -> String {
        key.lowercased().filter { $0 != "_" && $0 != "-" }
    }

    /// Body excerpt with sensitive JSON keys redacted first. Redaction must run
    /// on the FULL body before the excerpt (a truncated body no longer parses
    /// as JSON). `sensitiveKeys` must contain normalized keys.
    static func redactedBodyExcerpt(_ data: Data, sensitiveKeys: Set<String>) -> (text: String, isTruncated: Bool) {
        bodyExcerpt(redactedJSONBody(data, sensitiveKeys: sensitiveKeys) ?? data)
    }

    /// Returns nil — leaving the original bytes untouched — when the body is
    /// not JSON or contains no sensitive keys.
    static func redactedJSONBody(_ data: Data, sensitiveKeys: Set<String>) -> Data? {
        guard let first = data.first,
              first == UInt8(ascii: "{") || first == UInt8(ascii: "["),
              let object = try? JSONSerialization.jsonObject(with: data)
        else { return nil }

        var didRedact = false
        func redact(_ value: Any) -> Any {
            switch value {
            case let dictionary as [String: Any]:
                var result: [String: Any] = [:]
                result.reserveCapacity(dictionary.count)
                for (key, entry) in dictionary {
                    if sensitiveKeys.contains(normalizedBodyKey(key)) {
                        result[key] = redactedValue
                        didRedact = true
                    } else {
                        result[key] = redact(entry)
                    }
                }
                return result
            case let array as [Any]:
                return array.map(redact)
            default:
                return value
            }
        }
        let redacted = redact(object)
        guard didRedact else { return nil }
        return try? JSONSerialization.data(withJSONObject: redacted, options: [.sortedKeys])
    }

    static func bodyExcerpt(_ data: Data) -> (text: String, isTruncated: Bool) {
        guard data.count > bodyExcerptByteLimit else {
            return (String(decoding: data, as: UTF8.self), false)
        }
        return (String(decoding: data.prefix(bodyExcerptByteLimit), as: UTF8.self), true)
    }

    // MARK: JSON helpers

    static func jsonString(fromJSONObject object: [String: Any]) -> String? {
        guard !object.isEmpty else { return nil }
        let sanitized = sanitizedJSONValue(object)
        guard let data = try? JSONSerialization.data(withJSONObject: sanitized, options: [.sortedKeys]) else {
            return nil
        }
        return String(decoding: data, as: UTF8.self)
    }

    private static func sanitizedJSONValue(_ value: Any) -> Any {
        switch value {
        case let dictionary as [String: Any]:
            return dictionary.mapValues { sanitizedJSONValue($0) }
        case let array as [Any]:
            return array.map { sanitizedJSONValue($0) }
        case let string as String:
            return string
        case let number as NSNumber:
            return number
        case is NSNull:
            return NSNull()
        default:
            return String(describing: value)
        }
    }
    #endif
}
