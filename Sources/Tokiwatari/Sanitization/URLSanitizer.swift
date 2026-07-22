#if DEBUG
import Foundation

/// Rebuilds URLs for storage: strips userinfo and fragment, and redacts every
/// query value whose parameter name is not allowlisted. When the URL cannot be
/// parsed, stores `<unavailable>` — never a fragment of `absoluteString`.
enum URLSanitizer {
    static func sanitizedString(_ url: URL?, allowedQueryParameters: Set<String>) -> String? {
        guard let url else { return nil }
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: true) else {
            return SanitizationMarkers.unavailable
        }
        components.user = nil
        components.password = nil
        components.fragment = nil
        if let items = components.queryItems, !items.isEmpty {
            components.queryItems = items.map { item in
                guard item.value != nil, !allowedQueryParameters.contains(item.name) else {
                    return item
                }
                return URLQueryItem(name: item.name, value: SanitizationMarkers.redacted)
            }
        }
        guard let rebuilt = components.string else {
            return SanitizationMarkers.unavailable
        }
        return StringSanitizer.sanitized(rebuilt, maximumBytes: SanitizationLimits.sanitizedURLByteLimit)
    }
}
#endif
