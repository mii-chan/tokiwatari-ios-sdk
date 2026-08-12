import Foundation

/// Shared string bounding used by identifiers, URLs, headers and error
/// domains: control-character normalization plus UTF-8-boundary-safe byte
/// truncation with a trailing `<truncated>` marker.
enum StringSanitizer {
    static let truncationMarker = "<truncated>"

    static func sanitized(_ string: String, maximumBytes: Int) -> String {
        let normalized = normalizedControlCharacters(string)
        guard normalized.utf8.count > maximumBytes else { return normalized }
        let budget = max(0, maximumBytes - truncationMarker.utf8.count)
        return utf8SafePrefix(normalized, maximumBytes: budget) + truncationMarker
    }

    static func normalizedControlCharacters(_ string: String) -> String {
        guard string.unicodeScalars.contains(where: isControl) else { return string }
        var scalars = String.UnicodeScalarView()
        for scalar in string.unicodeScalars {
            scalars.append(isControl(scalar) ? "\u{FFFD}" : scalar)
        }
        return String(scalars)
    }

    /// Truncates to at most `maximumBytes` UTF-8 bytes without splitting a
    /// multi-byte character.
    static func utf8SafePrefix(_ string: String, maximumBytes: Int) -> String {
        let bytes = Array(string.utf8)
        guard bytes.count > maximumBytes else { return string }
        var end = max(0, maximumBytes)
        while end > 0, bytes[end] & 0b1100_0000 == 0b1000_0000 { end -= 1 }
        return String(decoding: bytes[..<end], as: UTF8.self)
    }

    private static func isControl(_ scalar: Unicode.Scalar) -> Bool {
        scalar.value < 0x20 || (0x7F...0x9F).contains(scalar.value)
    }
}
