import Foundation
import Synchronization
#if canImport(UIKit)
import UIKit
#endif

/// Supplies the (session id, sequence) pairs that order the timeline.
///
/// Implementations MUST (1) make `next()` thread-safe, (2) return strictly
/// monotonically increasing sequences within a session, and (3) be shared as
/// a single instance by all loggers.
public protocol TokiwatariSessionProviding: Sendable {
    /// Atomically returns the current session id and the next sequence value.
    func next() -> (sessionId: String, sequence: Int64)

    var currentId: String { get }
}

/// Default session provider: a new session starts at `init()` and on
/// foreground return after more than `timeout` of inactivity.
public final class TokiwatariLogSession: TokiwatariSessionProviding {
    private struct State {
        var id: String
        var sequence: Int64
        var lastActivity: Date
    }

    private let state: Mutex<State>
    private let timeout: TimeInterval
    // nonisolated(unsafe) is sound here: written in init, read in deinit, never concurrently.
    private nonisolated(unsafe) var foregroundObserver: NSObjectProtocol?

    public init(timeout: TimeInterval = 30 * 60) {
        self.timeout = timeout
        self.state = Mutex(State(id: UUID().uuidString, sequence: 0, lastActivity: Date()))
        // DEBUG-only so that Release `configure()` (whose default argument
        // constructs this) stays entirely side-effect free.
        #if DEBUG && canImport(UIKit)
        foregroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.startNewSessionIfTimedOut()
        }
        #endif
    }

    deinit {
        if let foregroundObserver {
            NotificationCenter.default.removeObserver(foregroundObserver)
        }
    }

    public func next() -> (sessionId: String, sequence: Int64) {
        state.withLock { s -> (sessionId: String, sequence: Int64) in
            s.sequence += 1
            s.lastActivity = Date()
            return (s.id, s.sequence)
        }
    }

    public var currentId: String {
        state.withLock { $0.id }
    }

    /// Manually starts a new session (id renewal + sequence reset).
    public func startNewSession() {
        state.withLock { s in
            s.id = UUID().uuidString
            s.sequence = 0
            s.lastActivity = Date()
        }
    }

    func startNewSessionIfTimedOut(now: Date = Date()) {
        state.withLock { s in
            guard now.timeIntervalSince(s.lastActivity) >= timeout else { return }
            s.id = UUID().uuidString
            s.sequence = 0
            s.lastActivity = now
        }
    }
}
