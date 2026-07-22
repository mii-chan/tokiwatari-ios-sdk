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
    /// Configuration failures leave the SDK inactive and raise a DEBUG
    /// assertion. Sensitive entries must be nonempty, at most 256 UTF-8 bytes,
    /// and at most 256 distinct normalized values per list.
    ///
    /// - Parameters:
    ///   - session: session provider shared by the UI and API loggers.
    ///   - allowedQueryParameters: query parameter names whose values are kept
    ///     in stored URLs; every other query value becomes `<redacted>`. Never
    ///     allow authentication or signature parameters. Do not put secrets in
    ///     URL paths — paths are stored as-is for endpoint identification.
    ///   - retentionSessions: number of most-recent sessions to keep; all rows
    ///     of older sessions are deleted at configure time.
    ///   - maximumMainDatabaseSizeBytes: page-count cap for the main SQLite
    ///     file. Not a hard cap on total disk usage (WAL/SHM/temporary files
    ///     and exports are not included).
    ///   - maximumRetainedWALSizeBytes: WAL size the SDK tries to stay under.
    ///   - additionalSensitiveHeaderNames: header names (case-insensitive)
    ///     recorded as `<redacted>`, in addition to the built-in set. Built-ins
    ///     cannot be opted out of.
    ///   - additionalSensitiveBodyKeys: JSON body keys recorded as `<redacted>`,
    ///     in addition to the built-in set; matching ignores case and `_`/`-`
    ///     and recurses into nested values. Built-ins cannot be opted out of.
    ///     Built-in redaction is defense in depth, not a guarantee — add your
    ///     app-specific keys here.
    public static func configure(
        session: any TokiwatariSessionProviding = TokiwatariLogSession(),
        allowedQueryParameters: [String] = [],
        retentionSessions: Int = 10,
        maximumMainDatabaseSizeBytes: Int = 128 * 1024 * 1024,
        maximumRetainedWALSizeBytes: Int = 16 * 1024 * 1024,
        additionalSensitiveHeaderNames: [String] = [],
        additionalSensitiveBodyKeys: [String] = []
    ) {
        #if DEBUG
        configure(
            session: session,
            allowedQueryParameters: allowedQueryParameters,
            retentionSessions: retentionSessions,
            maximumMainDatabaseSizeBytes: maximumMainDatabaseSizeBytes,
            maximumRetainedWALSizeBytes: maximumRetainedWALSizeBytes,
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
    /// (`event_kind = 'ui'`, `payload_json = parameters`).
    public static func log(_ event: TokiwatariEvent) {
        #if DEBUG
        let payloadJson = jsonString(fromJSONObject: event.parameters)
        guard let slot = nextEventSlot() else { return }
        let record = EventRecord(
            sessionId: slot.sessionId,
            sessionSequence: slot.sequence,
            timestamp: Date(),
            eventKind: "ui",
            identifier: event.identifier,
            httpMethod: nil,
            url: nil,
            statusCode: nil,
            durationMs: nil,
            payloadJson: payloadJson
        )
        slot.database.insertAsync(record)
        #endif
    }

    /// Convenience overload of `log(_:)` for one-off events.
    public static func log(identifier: String, parameters: [String: Any] = [:]) {
        log(TokiwatariEvent(identifier: identifier, parameters: parameters))
    }

    /// Records one API call on the debug timeline (`event_kind = 'api'`).
    ///
    /// Inputs are sanitized synchronously on the calling thread; only an
    /// immutable snapshot is handed to the writer queue. `identifier` is NOT
    /// subject to redaction — never put secrets in it.
    public static func logAPIEvent(
        identifier: String? = nil,
        request: URLRequest,
        response: HTTPURLResponse? = nil,
        responseBody: Data? = nil,
        error: (any Error)? = nil,
        start: Date,
        end: Date
    ) {
        #if DEBUG
        guard let context = sanitizationContext() else { return }
        var record = sanitizedAPIEventRecord(
            identifier: identifier,
            request: request,
            response: response,
            responseBody: responseBody,
            error: error,
            start: start,
            end: end,
            context: context
        )
        guard let slot = nextEventSlot() else { return }
        record.sessionId = slot.sessionId
        record.sessionSequence = slot.sequence
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

    // MARK: - Internal (DEBUG only)

    #if DEBUG
    private struct GlobalState {
        var session: (any TokiwatariSessionProviding)?
        var database: TokiwatariDatabase?
        var sensitiveHeaderNames: Set<String> = Tokiwatari.defaultSensitiveHeaderNames
        var sensitiveBodyKeys: Set<String> = Tokiwatari.defaultSensitiveBodyKeys
        var allowedQueryParameters: Set<String> = []
        var maximumMainDatabaseSizeBytes: Int = 128 * 1024 * 1024
        var maximumRetainedWALSizeBytes: Int = 16 * 1024 * 1024
        var maximumPayloadBytes: Int = SanitizationLimits.maximumPayloadBytes
        // Watermark for the sequence-monotonicity assertion in nextEventSlot().
        var lastSessionId: String?
        var lastSequence: Int64 = 0
    }

    static let minimumMainDatabaseSizeBytes = 1024 * 1024
    static let minimumRetainedWALSizeBytes = 256 * 1024

    struct SanitizationContext {
        var sensitiveHeaderNames: Set<String>
        var sensitiveBodyKeys: Set<String>
        var allowedQueryParameters: Set<String>
        var maximumPayloadBytes: Int
    }

    private static func sanitizationContext() -> SanitizationContext? {
        state.withLock { s in
            guard s.database != nil, s.session != nil else { return nil }
            return SanitizationContext(
                sensitiveHeaderNames: s.sensitiveHeaderNames,
                sensitiveBodyKeys: s.sensitiveBodyKeys,
                allowedQueryParameters: s.allowedQueryParameters,
                maximumPayloadBytes: s.maximumPayloadBytes
            )
        }
    }

    private static let state = Mutex(GlobalState())
    private static let bootstrapped = Mutex(false)
    private static let checkpointTimer = Mutex<(any DispatchSourceTimer)?>(nil)
    private static let checkpointInterval: TimeInterval = 30

    /// Internal configuration hooks used by tests.
    static func configure(
        session: any TokiwatariSessionProviding,
        allowedQueryParameters: [String] = [],
        retentionSessions: Int = 10,
        maximumMainDatabaseSizeBytes: Int = 128 * 1024 * 1024,
        maximumRetainedWALSizeBytes: Int = 16 * 1024 * 1024,
        additionalSensitiveHeaderNames: [String] = [],
        additionalSensitiveBodyKeys: [String] = [],
        maximumPayloadBytesForTesting: Int? = nil,
        assertingValidity: Bool = true,
        databaseURL: URL?
    ) {
        state.withLock { s in
            s.session = nil
            s.database = nil
            s.lastSessionId = nil
            s.lastSequence = 0
        }

        let queryParameters = sanitizedAllowedQueryParameters(
            allowedQueryParameters,
            assertingValidity: assertingValidity
        )

        var headerNames: Set<String> = []
        var bodyKeys: Set<String> = []
        var database: TokiwatariDatabase?
        var failure: (any Error)?
        do {
            headerNames = try validatedSensitiveEntries(additionalSensitiveHeaderNames, kind: .headerName) {
                $0.lowercased()
            }
            bodyKeys = try validatedSensitiveEntries(additionalSensitiveBodyKeys, kind: .bodyKey) {
                normalizedBodyKey($0)
            }
            let url = try databaseURL ?? TokiwatariDatabase.defaultDatabaseURL()
            let db = try TokiwatariDatabase(url: url)
            try db.purge(keepingSessions: max(1, retentionSessions))
            database = db
        } catch {
            failure = error
            database = nil
        }
        state.withLock { s in
            s.session = database == nil ? nil : session
            s.database = database
            s.sensitiveHeaderNames = defaultSensitiveHeaderNames.union(headerNames)
            s.sensitiveBodyKeys = defaultSensitiveBodyKeys.union(bodyKeys)
            s.allowedQueryParameters = queryParameters
            s.maximumMainDatabaseSizeBytes = max(minimumMainDatabaseSizeBytes, maximumMainDatabaseSizeBytes)
            s.maximumRetainedWALSizeBytes = max(minimumRetainedWALSizeBytes, maximumRetainedWALSizeBytes)
            s.maximumPayloadBytes = maximumPayloadBytesForTesting ?? SanitizationLimits.maximumPayloadBytes
            s.lastSessionId = nil
            s.lastSequence = 0
        }
        if let failure {
            print("Tokiwatari: configure failed — logging is disabled: \(failure)")
            if assertingValidity {
                assertionFailure("Tokiwatari: configure failed — logging is disabled: \(failure)")
            }
        }
        bootstrapIfNeeded()
    }

    /// Invalid allowlist entries are dropped, which only increases redaction.
    static func sanitizedAllowedQueryParameters(
        _ values: [String],
        assertingValidity: Bool = true
    ) -> Set<String> {
        var result: Set<String> = []
        var droppedInvalid = false
        for value in values {
            guard !value.isEmpty,
                  value.utf8.count <= SanitizationLimits.configurationEntryByteLimit
            else {
                droppedInvalid = true
                continue
            }
            guard result.count < SanitizationLimits.configurationEntryCountLimit else {
                droppedInvalid = true
                break
            }
            result.insert(StringSanitizer.normalizedControlCharacters(value))
        }
        if assertingValidity, droppedInvalid {
            assertionFailure(
                "Tokiwatari: invalid allowedQueryParameters entries were dropped (empty, over-length or over-count)"
            )
        }
        return result
    }

    enum SensitiveEntryKind: String, Sendable {
        case headerName = "additionalSensitiveHeaderNames"
        case bodyKey = "additionalSensitiveBodyKeys"
    }

    enum ConfigurationError: Error, CustomStringConvertible {
        case invalidSensitiveEntry(SensitiveEntryKind)
        case tooManySensitiveEntries(SensitiveEntryKind)

        var description: String {
            switch self {
            case .invalidSensitiveEntry(let kind):
                "\(kind.rawValue) contains an empty or over-long entry"
            case .tooManySensitiveEntries(let kind):
                "\(kind.rawValue) exceeds \(SanitizationLimits.configurationEntryCountLimit) entries"
            }
        }
    }

    /// Invalid sensitive entries fail configuration instead of weakening redaction.
    static func validatedSensitiveEntries(
        _ values: [String],
        kind: SensitiveEntryKind,
        normalize: (String) -> String
    ) throws -> Set<String> {
        var result: Set<String> = []
        for value in values {
            guard !value.isEmpty,
                  value.utf8.count <= SanitizationLimits.configurationEntryByteLimit
            else {
                throw ConfigurationError.invalidSensitiveEntry(kind)
            }
            result.insert(normalize(StringSanitizer.normalizedControlCharacters(value)))
            guard result.count <= SanitizationLimits.configurationEntryCountLimit else {
                throw ConfigurationError.tooManySensitiveEntries(kind)
            }
        }
        return result
    }

    private static func bootstrapIfNeeded() {
        let isFirst = bootstrapped.withLock { flag -> Bool in
            if flag { return false }
            flag = true
            return true
        }
        guard isFirst else { return }

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

    // MARK: API event recording

    /// Builds the immutable, fully sanitized event snapshot on the calling
    /// thread. Session id/sequence are filled in later under the SDK lock.
    static func sanitizedAPIEventRecord(
        identifier: String?,
        request: URLRequest,
        response: HTTPURLResponse?,
        responseBody: Data?,
        error: (any Error)?,
        start: Date,
        end: Date,
        context: SanitizationContext
    ) -> EventRecord {
        EventRecord(
            sessionId: "",
            sessionSequence: 0,
            timestamp: end,
            eventKind: "api",
            identifier: identifier.map {
                StringSanitizer.sanitized($0, maximumBytes: SanitizationLimits.identifierByteLimit)
            },
            httpMethod: request.httpMethod.map {
                StringSanitizer.sanitized($0, maximumBytes: SanitizationLimits.httpMethodByteLimit)
            },
            url: nil,
            statusCode: response?.statusCode,
            durationMs: clampedDurationMilliseconds(start: start, end: end),
            payloadJson: nil
        )
    }

    static func clampedDurationMilliseconds(start: Date, end: Date) -> Int {
        let seconds = end.timeIntervalSince(start)
        guard seconds.isFinite, seconds > 0 else { return 0 }
        return Int(min(seconds * 1000, SanitizationLimits.maximumDurationMilliseconds).rounded())
    }

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
