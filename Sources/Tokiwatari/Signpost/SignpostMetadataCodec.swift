import Foundation

/// Fixed-order ASCII `key=value` tokens with a correlation prefix and an
/// `end=1` terminator that identifies complete messages.
enum SignpostMetadataCodec {

    /// Conservative budget below the logging system's ~1 KB limit.
    static let maximumMetadataBytes = 768

    // MARK: - Encoding

    static func encodedUIMetadata(
        sessionId: String,
        sessionSequence: Int64,
        identifier: String
    ) -> String? {
        encodedMetadata(
            fixedTokens: [
                "v=1",
                "session_id=\(percentEncoded(sessionId))",
                "session_sequence=\(sessionSequence)",
            ],
            identifier: identifier
        )
    }

    static func encodedAPIMetadata(
        sessionId: String,
        sessionSequence: Int64,
        method: String?,
        status: Int?,
        durationMs: Int,
        identifier: String?
    ) -> String? {
        var tokens = [
            "v=1",
            "session_id=\(percentEncoded(sessionId))",
            "session_sequence=\(sessionSequence)",
        ]
        if let method {
            tokens.append("method=\(percentEncoded(method))")
        }
        if let status {
            tokens.append("status=\(status)")
        }
        tokens.append("duration_ms=\(durationMs)")
        return encodedMetadata(fixedTokens: tokens, identifier: identifier)
    }

    /// Returns nil when fixed tokens alone exceed the budget.
    private static func encodedMetadata(fixedTokens: [String], identifier: String?) -> String? {
        let endToken = "end=1"
        guard let identifier else {
            let message = (fixedTokens + [endToken]).joined(separator: " ")
            return message.utf8.count <= maximumMetadataBytes ? message : nil
        }

        let fullMessage = (fixedTokens + ["identifier=\(percentEncoded(identifier))", endToken])
            .joined(separator: " ")
        if fullMessage.utf8.count <= maximumMetadataBytes {
            return fullMessage
        }

        let framedPrefix = (fixedTokens + ["identifier_truncated=1", "identifier=", endToken])
            .joined(separator: " ")
        let budget = maximumMetadataBytes - framedPrefix.utf8.count
        guard budget > 0 else { return nil }
        var prefix = ""
        var usedBytes = 0
        for character in identifier {
            let encodedCharacter = percentEncoded(String(character))
            guard usedBytes + encodedCharacter.utf8.count <= budget else { break }
            prefix += encodedCharacter
            usedBytes += encodedCharacter.utf8.count
        }
        return (fixedTokens + ["identifier_truncated=1", "identifier=\(prefix)", endToken])
            .joined(separator: " ")
    }

    // MARK: - Percent encoding

    private static let hexDigits: [Character] = Array("0123456789ABCDEF")

    static func percentEncoded(_ string: String) -> String {
        var result = ""
        result.reserveCapacity(string.utf8.count)
        for byte in string.utf8 {
            if isUnreservedByte(byte) {
                result.append(Character(UnicodeScalar(byte)))
            } else {
                result.append("%")
                result.append(hexDigits[Int(byte >> 4)])
                result.append(hexDigits[Int(byte & 0x0F)])
            }
        }
        return result
    }

    private static func isUnreservedByte(_ byte: UInt8) -> Bool {
        switch byte {
        case UInt8(ascii: "A")...UInt8(ascii: "Z"),
             UInt8(ascii: "a")...UInt8(ascii: "z"),
             UInt8(ascii: "0")...UInt8(ascii: "9"),
             UInt8(ascii: "-"), UInt8(ascii: "."),
             UInt8(ascii: "_"), UInt8(ascii: "~"):
            true
        default:
            false
        }
    }

    static func strictPercentDecoded(_ value: some StringProtocol) -> String? {
        let utf8 = Array(value.utf8)
        var bytes: [UInt8] = []
        bytes.reserveCapacity(utf8.count)
        var index = 0
        while index < utf8.count {
            let byte = utf8[index]
            if byte == UInt8(ascii: "%") {
                guard index + 2 < utf8.count,
                      let high = hexValue(utf8[index + 1]),
                      let low = hexValue(utf8[index + 2])
                else { return nil }
                bytes.append(high << 4 | low)
                index += 3
            } else if isUnreservedByte(byte) {
                bytes.append(byte)
                index += 1
            } else {
                return nil
            }
        }
        return String(bytes: bytes, encoding: .utf8)
    }

    private static func hexValue(_ byte: UInt8) -> UInt8? {
        switch byte {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): byte - UInt8(ascii: "0")
        case UInt8(ascii: "A")...UInt8(ascii: "F"): byte - UInt8(ascii: "A") + 10
        case UInt8(ascii: "a")...UInt8(ascii: "f"): byte - UInt8(ascii: "a") + 10
        default: nil
        }
    }

    // MARK: - Decoding

    enum EventKind: Sendable {
        case ui
        case api
    }

    struct OptionalFields: Equatable, Sendable {
        var method: String?
        var status: Int64?
        var durationMs: Int64?
        var identifier: String?
        var identifierTruncated = false
    }

    struct ParsedSignpostMetadata: Equatable, Sendable {
        let sessionId: String
        let sessionSequence: Int64
        let optionalFields: OptionalFields?
        let metadataComplete: Bool
    }

    /// Rejects an invalid correlation prefix; an invalid tail returns only the
    /// correlation with `metadataComplete == false`.
    static func parsed(_ message: String, kind: EventKind) -> ParsedSignpostMetadata? {
        let tokens = message.split(separator: " ", omittingEmptySubsequences: false)
        guard tokens.count >= 3,
              tokens[0] == "v=1",
              let sessionIdValue = value(of: tokens[1], key: "session_id"),
              let sessionId = strictPercentDecoded(sessionIdValue),
              !sessionId.isEmpty,
              sessionId.utf8.count <= SanitizationLimits.sessionIdByteLimit,
              let sequenceValue = value(of: tokens[2], key: "session_sequence"),
              let sequence = Int64(sequenceValue)
        else { return nil }

        let tail = tokens[3...]
        guard !tail.contains(where: { $0.hasPrefix("v=") }) else { return nil }

        let fields: OptionalFields? = switch kind {
        case .ui: parsedUITail(tail)
        case .api: parsedAPITail(tail)
        }
        return ParsedSignpostMetadata(
            sessionId: sessionId,
            sessionSequence: sequence,
            optionalFields: fields,
            metadataComplete: fields != nil
        )
    }

    static func strictlyParsed(_ message: String, kind: EventKind) -> ParsedSignpostMetadata? {
        guard let parsed = parsed(message, kind: kind), parsed.metadataComplete else { return nil }
        return parsed
    }

    private static func value(of token: Substring, key: String) -> Substring? {
        guard let separator = token.firstIndex(of: "="), token[..<separator] == key else {
            return nil
        }
        return token[token.index(after: separator)...]
    }

    private static func parsedUITail(_ tokens: ArraySlice<Substring>) -> OptionalFields? {
        var fields = OptionalFields()
        var index = tokens.startIndex
        if index < tokens.endIndex, let flag = value(of: tokens[index], key: "identifier_truncated") {
            guard flag == "1" else { return nil }
            fields.identifierTruncated = true
            index += 1
        }
        guard index < tokens.endIndex,
              let raw = value(of: tokens[index], key: "identifier"),
              let identifier = strictPercentDecoded(raw),
              identifier.utf8.count <= SanitizationLimits.identifierByteLimit
        else { return nil }
        fields.identifier = identifier
        index += 1
        guard index == tokens.endIndex - 1, tokens[index] == "end=1" else { return nil }
        return fields
    }

    private static func parsedAPITail(_ tokens: ArraySlice<Substring>) -> OptionalFields? {
        var fields = OptionalFields()
        var index = tokens.startIndex
        if index < tokens.endIndex, let raw = value(of: tokens[index], key: "method") {
            guard let method = strictPercentDecoded(raw),
                  method.utf8.count <= SanitizationLimits.httpMethodByteLimit
            else { return nil }
            fields.method = method
            index += 1
        }
        if index < tokens.endIndex, let raw = value(of: tokens[index], key: "status") {
            guard let status = Int64(raw) else { return nil }
            fields.status = status
            index += 1
        }
        guard index < tokens.endIndex,
              let rawDuration = value(of: tokens[index], key: "duration_ms"),
              let duration = Int64(rawDuration),
              (0...Int64(SanitizationLimits.maximumDurationMilliseconds)).contains(duration)
        else { return nil }
        fields.durationMs = duration
        index += 1
        if index < tokens.endIndex, let flag = value(of: tokens[index], key: "identifier_truncated") {
            guard flag == "1" else { return nil }
            fields.identifierTruncated = true
            index += 1
        }
        if index < tokens.endIndex, let raw = value(of: tokens[index], key: "identifier") {
            guard let identifier = strictPercentDecoded(raw),
                  identifier.utf8.count <= SanitizationLimits.identifierByteLimit
            else { return nil }
            fields.identifier = identifier
            index += 1
        }
        guard !fields.identifierTruncated || fields.identifier != nil else { return nil }
        guard index == tokens.endIndex - 1, tokens[index] == "end=1" else { return nil }
        return fields
    }
}
