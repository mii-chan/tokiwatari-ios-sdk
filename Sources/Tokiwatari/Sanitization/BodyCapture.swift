import Foundation

/// Allowlist-based body capture. Invariant: oversized, unknown-format or
/// partial data is dropped entirely — raw bytes are never stored as fallback.
enum BodyCapture {
    enum Unavailable: String {
        case tooLarge = "too_large"
        case sanitizedTooLarge = "sanitized_body_too_large"
        case complexityLimit = "json_complexity_limit"
        case invalidJSON = "invalid_json"
        case unsupportedContentType = "unsupported_content_type"
        case multipart = "multipart"
        case streamed = "streamed"
    }

    enum Result {
        case absent
        case stored(Any)
        case unavailable(Unavailable, originalBytes: Int?)

        var payloadValue: Any? {
            switch self {
            case .absent:
                return nil
            case .stored(let value):
                return value
            case .unavailable(let reason, let originalBytes):
                var marker: [String: Any] = ["body_unavailable": reason.rawValue]
                if let originalBytes { marker["original_bytes"] = originalBytes }
                return marker
            }
        }
    }

    enum Role {
        case request
        case response
    }

    /// Normalized media type: lowercased, parameters (charset etc.) removed.
    struct ContentType {
        let type: String
        let subtype: String

        init?(headerValue: String) {
            let mediaType = headerValue
                .split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false)[0]
                .trimmingCharacters(in: .whitespaces)
                .lowercased()
            guard let slash = mediaType.firstIndex(of: "/") else { return nil }
            let type = String(mediaType[..<slash])
            let subtype = String(mediaType[mediaType.index(after: slash)...])
            guard !type.isEmpty, !subtype.isEmpty else { return nil }
            self.type = type
            self.subtype = subtype
        }

        /// `application/json` and `application/*+json` only; `text/*` stays
        /// unsupported even with a `+json` suffix (allowlist policy).
        var isJSON: Bool {
            type == "application" && (subtype == "json" || subtype.hasSuffix("+json"))
        }
    }

    static func capture(
        _ body: Data,
        contentTypeHeader: String?,
        role: Role,
        sanitizer: JSONSanitizer
    ) -> Result {
        guard !body.isEmpty else { return .absent }
        guard body.count <= SanitizationLimits.bodyProcessingByteLimit else {
            return .unavailable(.tooLarge, originalBytes: nil)
        }
        if let contentTypeHeader {
            guard let contentType = ContentType(headerValue: contentTypeHeader) else {
                return .unavailable(.unsupportedContentType, originalBytes: nil)
            }
            if contentType.isJSON {
                return jsonCapture(body, role: role, sanitizer: sanitizer, contentTypeWasPresent: true)
            }
            if contentType.type == "multipart" {
                return .unavailable(.multipart, originalBytes: nil)
            }
            return .unavailable(.unsupportedContentType, originalBytes: nil)
        }
        // No Content-Type: store only when the body fully parses as JSON.
        return jsonCapture(body, role: role, sanitizer: sanitizer, contentTypeWasPresent: false)
    }

    /// Strips a UTF-8 BOM and leading whitespace so BOM-prefixed JSON is
    /// recognized deterministically.
    static func normalizedJSONInput(_ body: Data) -> Data {
        var body = body
        if body.starts(with: [0xEF, 0xBB, 0xBF]) {
            body = body.dropFirst(3)
        }
        while let first = body.first, first == 0x20 || first == 0x09 || first == 0x0A || first == 0x0D {
            body = body.dropFirst()
        }
        return body
    }

    private static func jsonCapture(
        _ body: Data,
        role: Role,
        sanitizer: JSONSanitizer,
        contentTypeWasPresent: Bool
    ) -> Result {
        let body = normalizedJSONInput(body)
        guard let object = try? JSONSerialization.jsonObject(with: body, options: [.fragmentsAllowed]) else {
            return .unavailable(
                contentTypeWasPresent ? .invalidJSON : .unsupportedContentType,
                originalBytes: nil
            )
        }

        let sanitizedValue: Any
        do {
            switch role {
            case .request:
                sanitizedValue = try sanitizer.sanitized(omittingRequestQueryDocument(object))
            case .response:
                sanitizedValue = try sanitizer.sanitized(object)
            }
        } catch {
            return .unavailable(.complexityLimit, originalBytes: nil)
        }

        guard let data = try? JSONSerialization.data(
            withJSONObject: sanitizedValue,
            options: [.sortedKeys, .fragmentsAllowed]
        ) else {
            return .unavailable(.invalidJSON, originalBytes: nil)
        }
        guard data.count <= SanitizationLimits.maximumStoredBodyBytes else {
            return .unavailable(.sanitizedTooLarge, originalBytes: body.count)
        }
        return .stored(sanitizedValue)
    }

    /// Shallow pre-pass for request JSON, run before sanitization: the
    /// top-level string `query` — of a single object or of each top-level
    /// array element (GraphQL batches) — becomes `<omitted>`, GraphQL or not.
    /// Query documents can carry secrets that key redaction cannot catch, and
    /// dropping a REST `query` string is the safe direction. Nested wrappers
    /// are intentionally not covered. The pre-pass never walks into values, so
    /// the sanitizer's depth/node limits still apply to the body as a whole.
    static func omittingRequestQueryDocument(_ object: Any) -> Any {
        func omitQuery(_ value: Any) -> Any {
            guard var dictionary = value as? [String: Any] else { return value }
            if dictionary["query"] is String {
                dictionary["query"] = SanitizationMarkers.omitted
            }
            return dictionary
        }
        if let array = object as? [Any] {
            return array.map(omitQuery)
        }
        return omitQuery(object)
    }
}
