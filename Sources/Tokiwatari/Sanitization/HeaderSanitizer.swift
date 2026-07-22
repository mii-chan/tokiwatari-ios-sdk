#if DEBUG
import Foundation

/// Bounds and redacts HTTP header maps deterministically.
///
/// Sensitivity is matched against the FULL original name (before any
/// truncation), then names/values are normalized, sorted by a total order,
/// truncated, and finally the count and total-byte budgets are applied on the
/// actually-stored sizes.
enum HeaderSanitizer {
    /// `sensitiveNames` must contain lowercased names.
    static func sanitized(_ headers: [String: String], sensitiveNames: Set<String>) -> [String: String] {
        struct Entry {
            var normalizedName: String
            var originalName: String
            var value: String
        }
        var entries: [Entry] = []
        entries.reserveCapacity(headers.count)
        for (name, value) in headers {
            let isSensitive = sensitiveNames.contains(name.lowercased())
            entries.append(Entry(
                normalizedName: StringSanitizer.normalizedControlCharacters(name),
                originalName: name,
                value: isSensitive
                    ? SanitizationMarkers.redacted
                    : StringSanitizer.normalizedControlCharacters(value)
            ))
        }
        entries.sort {
            ($0.normalizedName, $0.originalName, $0.value) < ($1.normalizedName, $1.originalName, $1.value)
        }

        var result: [String: String] = [:]
        var totalBytes = 0
        for entry in entries {
            guard result.count < SanitizationLimits.headerCountLimit else { break }
            let name = StringSanitizer.sanitized(
                entry.normalizedName,
                maximumBytes: SanitizationLimits.headerNameByteLimit
            )
            // Deterministic first-wins on post-truncation name collisions.
            guard result[name] == nil else { continue }
            let value = StringSanitizer.sanitized(
                entry.value,
                maximumBytes: SanitizationLimits.headerValueByteLimit
            )
            let storedBytes = name.utf8.count + value.utf8.count
            guard totalBytes + storedBytes <= SanitizationLimits.allHeadersByteLimit else { break }
            totalBytes += storedBytes
            result[name] = value
        }
        return result
    }
}
#endif
