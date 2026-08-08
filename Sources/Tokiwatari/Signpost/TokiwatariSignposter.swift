import os

enum TokiwatariSignpostEventKind: Sendable {
    case ui
    case api
}

struct TokiwatariSignpostEvent: Sendable {
    let kind: TokiwatariSignpostEventKind
    let message: String
}

protocol TokiwatariSignpostEmitting: Sendable {
    var isEnabled: Bool { get }
    func emit(_ event: TokiwatariSignpostEvent)
}

/// Emits metadata as public so privacy redaction cannot break correlation.
final class TokiwatariSignposter: TokiwatariSignpostEmitting {
    static let subsystem = "com.tokiwatari"
    static let category = "events"
    static let uiEventName: StaticString = "TokiwatariUI"
    static let apiEventName: StaticString = "TokiwatariAPI"

    private let signposter = OSSignposter(subsystem: subsystem, category: category)

    var isEnabled: Bool { signposter.isEnabled }

    func emit(_ event: TokiwatariSignpostEvent) {
        switch event.kind {
        case .ui:
            signposter.emitEvent(Self.uiEventName, "\(event.message, privacy: .public)")
        case .api:
            signposter.emitEvent(Self.apiEventName, "\(event.message, privacy: .public)")
        }
    }
}
