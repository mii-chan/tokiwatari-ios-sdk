#if DEBUG
import Foundation

/// Assembles the final `payload_json` for API events.
enum EventPayloadEncoder {
    struct Components {
        var requestHeaders: [String: String]?
        var requestBody: Any?
        var responseHeaders: [String: String]?
        var responseBody: Any?
        var error: [String: Any]?

        var isEmpty: Bool {
            requestHeaders == nil && requestBody == nil
                && responseHeaders == nil && responseBody == nil && error == nil
        }

        var payloadObject: [String: Any] {
            var payload: [String: Any] = [:]
            var request: [String: Any] = [:]
            if let requestHeaders { request["headers"] = requestHeaders }
            if let requestBody { request["body"] = requestBody }
            if !request.isEmpty { payload["request"] = request }
            var response: [String: Any] = [:]
            if let responseHeaders { response["headers"] = responseHeaders }
            if let responseBody { response["body"] = responseBody }
            if !response.isEmpty { payload["response"] = response }
            if let error { payload["error"] = error }
            return payload
        }
    }

    static func encodedPayload(_ components: Components) -> String? {
        guard !components.isEmpty, let data = encode(components.payloadObject) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    static func encode(_ object: [String: Any]) -> Data? {
        try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }
}
#endif
