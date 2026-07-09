import Foundation

/// An event that can be recorded on the Tokiwatari debug timeline.
public protocol TokiwatariTrackable {
    /// Logical identifier (e.g. `tea_tapped_42`). Recorded as `identifier`.
    var logIdentifier: String { get }

    /// Event parameters. Persisted as JSON in `payload_json`.
    var parameters: [String: Any] { get }
}
