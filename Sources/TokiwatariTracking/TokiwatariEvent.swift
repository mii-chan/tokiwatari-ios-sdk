import Foundation

/// An event that can be recorded on the Tokiwatari debug timeline.
public struct TokiwatariEvent {
    /// Logical identifier (e.g. `tea_tapped_42`). Recorded as `identifier`.
    public let identifier: String

    /// Event parameters. Persisted as JSON in `payload_json`.
    public let parameters: [String: Any]

    public init(identifier: String, parameters: [String: Any] = [:]) {
        self.identifier = identifier
        self.parameters = parameters
    }
}
