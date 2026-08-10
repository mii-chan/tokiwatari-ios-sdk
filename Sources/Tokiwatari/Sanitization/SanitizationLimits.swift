import Foundation

/// Byte/count bounds applied to every stored string, JSON structure and final
/// payload. All limits are hard caps; exceeding data is truncated or dropped,
/// never stored raw.
enum SanitizationLimits {
    static let identifierByteLimit = 512
    static let sanitizedURLByteLimit = 8 * 1024
    static let httpMethodByteLimit = 32
    static let errorDomainByteLimit = 256

    static let headerNameByteLimit = 256
    static let headerValueByteLimit = 4 * 1024
    static let headerCountLimit = 100
    /// Per side (request headers and response headers each).
    static let allHeadersByteLimit = 32 * 1024

    /// Input-size cap for JSON parsing itself (parser-stage DoS protection).
    static let bodyProcessingByteLimit = 1024 * 1024
    /// Serialized sanitized body over this size is dropped entirely.
    static let maximumStoredBodyBytes = 64 * 1024
    /// Final encoded `payload_json` cap; exceeding payloads degrade in stages.
    static let maximumPayloadBytes = 256 * 1024
    static let maximumUIPayloadBytes = 64 * 1024

    /// Root container counts as depth 1.
    static let maximumJSONDepth = 64
    /// Dictionaries, arrays and scalars count 1 node each; keys are not counted.
    static let maximumJSONNodeCount = 10_000

    static let configurationEntryByteLimit = 256
    static let configurationEntryCountLimit = 256

    static let maximumDurationMilliseconds: Double = 7 * 24 * 60 * 60 * 1000
}

enum SanitizationMarkers {
    static let redacted = "<redacted>"
    static let unavailable = "<unavailable>"
    static let unsupported = "<unsupported>"
    static let omitted = "<omitted>"
    static let customErrorDomain = "<custom-error-domain>"
}
