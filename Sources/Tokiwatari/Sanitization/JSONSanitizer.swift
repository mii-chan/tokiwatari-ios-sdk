import Foundation

/// Shared JSON sanitizer for API bodies and UI parameters.
///
/// Recursively redacts sensitive keys and converts values to a bounded,
/// JSON-serializable form. Implemented with an explicit stack (no recursion),
/// with hard depth/node-count limits; cycles hit the depth limit and throw.
struct JSONSanitizer {
    /// Normalized via `Tokiwatari.normalizedBodyKey`.
    let sensitiveKeys: Set<String>
    let allowedQueryParameters: Set<String>

    enum SanitizerError: Error {
        case complexityLimitExceeded
    }

    func sanitized(_ root: Any) throws -> Any {
        var nodeCount = 0
        func countNode() throws {
            nodeCount += 1
            guard nodeCount <= SanitizationLimits.maximumJSONNodeCount else {
                throw SanitizerError.complexityLimitExceeded
            }
        }

        try countNode()
        guard let rootFrame = Frame(root, keyInParent: nil) else {
            return scalar(root)
        }
        var stack = [rootFrame]

        while let frame = stack.last {
            if frame.index < frame.childValues.count {
                let key = frame.childKeys?[frame.index]
                let child = frame.childValues[frame.index]
                frame.index += 1
                try countNode()
                if let key, sensitiveKeys.contains(Tokiwatari.normalizedBodyKey(key)) {
                    frame.attach(SanitizationMarkers.redacted, forKey: key)
                } else if let childFrame = Frame(child, keyInParent: key) {
                    guard stack.count < SanitizationLimits.maximumJSONDepth else {
                        throw SanitizerError.complexityLimitExceeded
                    }
                    stack.append(childFrame)
                } else {
                    frame.attach(scalar(child), forKey: key)
                }
            } else {
                stack.removeLast()
                if let parent = stack.last {
                    parent.attach(frame.result, forKey: frame.keyInParent)
                } else {
                    return frame.result
                }
            }
        }
        return NSNull()
    }

    private func scalar(_ value: Any) -> Any {
        switch value {
        case let string as String:
            return string
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return number }
            return number.doubleValue.isFinite ? number : SanitizationMarkers.unsupported
        case is NSNull:
            return NSNull()
        case let date as Date:
            return date.formatted(.iso8601)
        case let url as URL:
            return URLSanitizer.sanitizedString(url, allowedQueryParameters: allowedQueryParameters)
                ?? SanitizationMarkers.unavailable
        default:
            return SanitizationMarkers.unsupported
        }
    }

    private final class Frame {
        let childKeys: [String]?
        let childValues: [Any]
        let keyInParent: String?
        var index = 0
        private let isDictionary: Bool
        private var dictionaryResult: [String: Any] = [:]
        private var arrayResult: [Any] = []

        init?(_ value: Any, keyInParent: String?) {
            self.keyInParent = keyInParent
            if let dictionary = value as? [String: Any] {
                isDictionary = true
                let keys = Array(dictionary.keys)
                childKeys = keys
                childValues = keys.map { dictionary[$0]! }
                dictionaryResult.reserveCapacity(keys.count)
            } else if let array = value as? [Any] {
                isDictionary = false
                childKeys = nil
                childValues = array
                arrayResult.reserveCapacity(array.count)
            } else {
                return nil
            }
        }

        var result: Any { isDictionary ? dictionaryResult : arrayResult }

        func attach(_ value: Any, forKey key: String?) {
            if let key {
                dictionaryResult[key] = value
            } else {
                arrayResult.append(value)
            }
        }
    }
}
