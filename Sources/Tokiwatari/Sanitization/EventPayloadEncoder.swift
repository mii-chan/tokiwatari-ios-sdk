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

    /// Encodes the payload, degrading in stages when the encoded UTF-8 size
    /// exceeds `maximumPayloadBytes`: response body → request body →
    /// response headers → request headers → minimal event. The independent
    /// columns (method/url/status) live outside the payload and survive even
    /// full degradation.
    static func encodedPayload(
        _ components: Components,
        maximumPayloadBytes: Int = SanitizationLimits.maximumPayloadBytes
    ) -> String? {
        guard !components.isEmpty, let data = encode(components.payloadObject) else { return nil }
        guard data.count > maximumPayloadBytes else {
            return String(decoding: data, as: UTF8.self)
        }
        let originalBytes = data.count
        let droppedBody: [String: Any] = ["body_unavailable": "event_too_large"]

        var degraded = components
        let stages: [(inout Components) -> Bool] = [
            { c in
                guard c.responseBody != nil else { return false }
                c.responseBody = droppedBody
                return true
            },
            { c in
                guard c.requestBody != nil else { return false }
                c.requestBody = droppedBody
                return true
            },
            { c in
                guard c.responseHeaders != nil else { return false }
                c.responseHeaders = nil
                return true
            },
            { c in
                guard c.requestHeaders != nil else { return false }
                c.requestHeaders = nil
                return true
            },
        ]
        for stage in stages {
            guard stage(&degraded) else { continue }
            if let data = encode(degraded.payloadObject), data.count <= maximumPayloadBytes {
                return String(decoding: data, as: UTF8.self)
            }
        }
        return #"{"payload_dropped":"event_too_large","original_bytes":\#(originalBytes)}"#
    }

    static func encode(_ object: [String: Any]) -> Data? {
        try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }
}
#endif
