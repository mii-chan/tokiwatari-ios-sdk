import Foundation
import Testing
@testable import Tokiwatari

@Suite struct SignpostMetadataCodecTests {

    private typealias Codec = SignpostMetadataCodec

    private func ui(sessionId: String = "A", sequence: Int64 = 1, identifier: String) -> String? {
        Codec.encodedUIMetadata(sessionId: sessionId, sessionSequence: sequence, identifier: identifier)
    }

    // MARK: Field order and framing

    @Test func uiMessageUsesTheDocumentedFieldOrder() {
        let message = ui(sequence: 118, identifier: "favorite_button")
        #expect(message == "v=1 session_id=A session_sequence=118 identifier=favorite_button end=1")
    }

    @Test func apiMessageUsesTheDocumentedFieldOrder() {
        let message = Codec.encodedAPIMetadata(
            sessionId: "A",
            sessionSequence: 119,
            method: "POST",
            status: 200,
            durationMs: 87,
            identifier: "foo bar=baz"
        )
        #expect(
            message ==
                "v=1 session_id=A session_sequence=119 method=POST status=200 duration_ms=87 identifier=foo%20bar%3Dbaz end=1"
        )
    }

    @Test func absentOptionalAPIFieldsOmitTheirTokens() {
        let message = Codec.encodedAPIMetadata(
            sessionId: "A",
            sessionSequence: 1,
            method: nil,
            status: nil,
            durationMs: 5,
            identifier: nil
        )
        #expect(message == "v=1 session_id=A session_sequence=1 duration_ms=5 end=1")
    }

    @Test func emptyUIIdentifierKeepsItsToken() {
        #expect(ui(identifier: "") == "v=1 session_id=A session_sequence=1 identifier= end=1")
    }

    @Test func everyEncoderOutputEndsWithTheEndToken() {
        let messages = [
            ui(identifier: "plain"),
            ui(identifier: String(repeating: "長", count: 400)),
            Codec.encodedAPIMetadata(
                sessionId: "A", sessionSequence: 1,
                method: "GET", status: 200, durationMs: 1, identifier: nil
            ),
        ]
        for message in messages {
            #expect(message?.hasSuffix(" end=1") == true)
        }
    }

    // MARK: Percent encoding

    @Test func unreservedCharactersPassThrough() {
        let unreserved = "ABCXYZabcxyz0189-._~"
        #expect(Codec.percentEncoded(unreserved) == unreserved)
    }

    @Test func reservedCharactersUseUppercaseHexTriplets() {
        #expect(Codec.percentEncoded(" ") == "%20")
        #expect(Codec.percentEncoded("=") == "%3D")
        #expect(Codec.percentEncoded("%") == "%25")
        #expect(Codec.percentEncoded("+") == "%2B")
        #expect(Codec.percentEncoded("\u{FFFD}") == "%EF%BF%BD")
        #expect(Codec.percentEncoded("茶") == "%E8%8C%B6")
    }

    @Test func decodeAcceptsLowercaseHexButNeverConvertsPlusToSpace() {
        #expect(Codec.strictPercentDecoded("%2b") == "+")
        #expect(Codec.strictPercentDecoded("%e8%8c%b6") == "茶")
        #expect(Codec.strictPercentDecoded("a+b") == nil)
    }

    @Test func strictDecodeRejectsMalformedInput() {
        #expect(Codec.strictPercentDecoded("%2") == nil)
        #expect(Codec.strictPercentDecoded("%GG") == nil)
        #expect(Codec.strictPercentDecoded("%") == nil)
        #expect(Codec.strictPercentDecoded("a b") == nil)
        #expect(Codec.strictPercentDecoded("a=b") == nil)
        #expect(Codec.strictPercentDecoded("茶") == nil)
        #expect(Codec.strictPercentDecoded("%FF") == nil)
        #expect(Codec.strictPercentDecoded("%E8%8C") == nil)
    }

    @Test func sessionIdEncodingIsBoundedBy384Bytes() {
        let sessionId = String(repeating: "%", count: SanitizationLimits.sessionIdByteLimit)
        #expect(Codec.percentEncoded(sessionId).utf8.count == 384)
    }

    // MARK: Round trips

    @Test func uiRoundTripPreservesHostileIdentifiers() throws {
        let identifiers = ["favorite button", "a=b", "100%", "a+b", "お茶🍵", "tap\u{FFFD}done", ""]
        for identifier in identifiers {
            let message = try #require(ui(identifier: identifier))
            let parsed = try #require(Codec.parsed(message, kind: .ui))
            #expect(parsed.metadataComplete)
            #expect(parsed.sessionId == "A")
            #expect(parsed.sessionSequence == 1)
            #expect(parsed.optionalFields?.identifier == identifier)
            #expect(parsed.optionalFields?.identifierTruncated == false)
        }
    }

    @Test func apiRoundTripPreservesAllFields() throws {
        let message = try #require(Codec.encodedAPIMetadata(
            sessionId: "session-8",
            sessionSequence: -42,
            method: "POST",
            status: -1,
            durationMs: 604_800_000,
            identifier: "toggle favorite"
        ))
        let parsed = try #require(Codec.strictlyParsed(message, kind: .api))
        #expect(parsed.sessionId == "session-8")
        #expect(parsed.sessionSequence == -42)
        #expect(parsed.optionalFields?.method == "POST")
        #expect(parsed.optionalFields?.status == -1)
        #expect(parsed.optionalFields?.durationMs == 604_800_000)
        #expect(parsed.optionalFields?.identifier == "toggle favorite")
    }

    @Test func absentAPIIdentifierAndEmptyUIIdentifierAreDistinguishable() throws {
        let api = try #require(Codec.encodedAPIMetadata(
            sessionId: "A", sessionSequence: 1,
            method: nil, status: nil, durationMs: 0, identifier: nil
        ))
        #expect(try #require(Codec.parsed(api, kind: .api)).optionalFields?.identifier == nil)

        let uiEmpty = try #require(ui(identifier: ""))
        #expect(try #require(Codec.parsed(uiEmpty, kind: .ui)).optionalFields?.identifier == "")
    }

    // MARK: Byte budget and truncation

    @Test func exactBudgetKeepsTheFullIdentifier() throws {
        let sessionId = String(repeating: "%", count: 128)
        let identifier = String(repeating: "x", count: 332)
        let message = try #require(ui(sessionId: sessionId, identifier: identifier))
        #expect(message.utf8.count == Codec.maximumMetadataBytes)
        #expect(!message.contains("identifier_truncated"))
        let parsed = try #require(Codec.strictlyParsed(message, kind: .ui))
        #expect(parsed.optionalFields?.identifier == identifier)
        #expect(parsed.optionalFields?.identifierTruncated == false)
    }

    @Test func oneByteOverBudgetSwitchesToTheTruncationBranch() throws {
        let sessionId = String(repeating: "%", count: 128)
        let identifier = String(repeating: "x", count: 333)
        let message = try #require(ui(sessionId: sessionId, identifier: identifier))
        #expect(message.utf8.count <= Codec.maximumMetadataBytes)
        #expect(message.contains("identifier_truncated=1"))
        let parsed = try #require(Codec.parsed(message, kind: .ui))
        #expect(parsed.metadataComplete)
        let prefix = try #require(parsed.optionalFields?.identifier)
        #expect(parsed.optionalFields?.identifierTruncated == true)
        #expect(identifier.hasPrefix(prefix))
        // The truncation framing reserves 459 bytes, leaving a 309-byte prefix.
        #expect(prefix.utf8.count == 309)
    }

    @Test func truncationRespectsExtendedGraphemeClusterBoundaries() throws {
        let family = "👨‍👩‍👧‍👦"  // 25 UTF-8 bytes, 75 encoded
        let sessionId = String(repeating: "%", count: 104)  // 381-byte identifier budget
        let identifier = String(repeating: "x", count: 300) + family + family
        let message = try #require(ui(sessionId: sessionId, identifier: identifier))
        #expect(message.utf8.count <= Codec.maximumMetadataBytes)
        let parsed = try #require(Codec.parsed(message, kind: .ui))
        let prefix = try #require(parsed.optionalFields?.identifier)
        #expect(parsed.optionalFields?.identifierTruncated == true)
        #expect(identifier.hasPrefix(prefix))
        #expect(prefix.utf8.count == 300 + 25)
    }

    @Test func truncatedCanonicalSuffixIsTreatedAsOpaqueContent() throws {
        let canonical = StringSanitizer.sanitized(
            String(repeating: "a", count: 600),
            maximumBytes: SanitizationLimits.identifierByteLimit
        )
        #expect(canonical.hasSuffix("<truncated>"))
        let message = try #require(ui(identifier: canonical))
        #expect(!message.contains("identifier_truncated"))
        let parsed = try #require(Codec.strictlyParsed(message, kind: .ui))
        #expect(parsed.optionalFields?.identifier == canonical)
        #expect(parsed.optionalFields?.identifierTruncated == false)
    }

    // A 692-byte session id leaves a 1-byte identifier budget.
    @Test func budgetTooSmallForOneGraphemeEmitsEmptyTruncatedIdentifier() throws {
        let sessionId = String(repeating: "s", count: 692)
        let message = try #require(Codec.encodedUIMetadata(
            sessionId: sessionId,
            sessionSequence: 1,
            identifier: "👨‍👩‍👧‍👦"
        ))
        #expect(message.hasSuffix(" identifier_truncated=1 identifier= end=1"))
        #expect(message.utf8.count <= Codec.maximumMetadataBytes)
    }

    @Test func fixedPortionOverrunReturnsNilInsteadOfAMalformedMessage() {
        // A 693-byte session id leaves no identifier budget at all.
        let sessionId = String(repeating: "s", count: 693)
        #expect(Codec.encodedUIMetadata(
            sessionId: sessionId,
            sessionSequence: 1,
            identifier: String(repeating: "x", count: 24)
        ) == nil)
        #expect(Codec.encodedAPIMetadata(
            sessionId: String(repeating: "s", count: 800),
            sessionSequence: 1,
            method: nil, status: nil, durationMs: 0, identifier: nil
        ) == nil)
    }

    // Worst-case API fixed portion: 591 bytes, a 136-byte identifier budget.
    @Test func worstCaseAPIFixedPortionMatchesTheDocumentedBudget() throws {
        let sessionId = String(repeating: "%", count: 128)
        let method = String(repeating: "%", count: 32)
        let withoutIdentifier = try #require(Codec.encodedAPIMetadata(
            sessionId: sessionId,
            sessionSequence: Int64.min,
            method: method,
            status: Int(Int64.min),
            durationMs: 604_800_000,
            identifier: nil
        ))
        #expect(withoutIdentifier.utf8.count - " end=1".utf8.count == 591)

        let truncated = try #require(Codec.encodedAPIMetadata(
            sessionId: sessionId,
            sessionSequence: Int64.min,
            method: method,
            status: Int(Int64.min),
            durationMs: 604_800_000,
            identifier: String(repeating: "x", count: 500)
        ))
        let prefixLength = try #require(
            Codec.parsed(truncated, kind: .api)?.optionalFields?.identifier?.utf8.count
        )
        #expect(prefixLength == 136)
    }

    // MARK: Decoding failures

    @Test func requiredPrefixFailuresRejectTheWholeMessage() {
        let messages = [
            "",
            "v=2 session_id=A session_sequence=1 identifier=x end=1",
            "v= session_id=A session_sequence=1 identifier=x end=1",
            "session_id=A session_sequence=1 identifier=x end=1",
            "v=1 session_sequence=1 identifier=x end=1",
            "v=1 session_id= session_sequence=1 identifier=x end=1",
            "v=1 session_id=%GG session_sequence=1 identifier=x end=1",
            "v=1 session_id=A session_sequence=abc identifier=x end=1",
            "v=1 session_id=A session_sequence=9223372036854775808 identifier=x end=1",
            "v=1 session_id=A sess",
            "v=1 session_id=A",
            "v=1 session_id=\(String(repeating: "s", count: 129)) session_sequence=1 identifier=x end=1",
            "v=1 session_id=A session_sequence=1 v=1 identifier=x end=1",
        ]
        for message in messages {
            #expect(Codec.parsed(message, kind: .ui) == nil, "unexpectedly parsed: \(message)")
        }
    }

    @Test func extremeInt64SequencesParse() throws {
        let message = "v=1 session_id=A session_sequence=-9223372036854775808 identifier=x end=1"
        let parsed = try #require(Codec.parsed(message, kind: .ui))
        #expect(parsed.sessionSequence == Int64.min)
    }

    @Test func invalidTailsRecoverCorrelationOnly() throws {
        let messages = [
            "v=1 session_id=A session_sequence=7",
            "v=1 session_id=A session_sequence=7 identifier=fo%2",
            "v=1 session_id=A session_sequence=7 identifier=x%E8%8C",
            "v=1 session_id=A session_sequence=7 identif",
            "v=1 session_id=A session_sequence=7 identifier=x",
            "v=1 session_id=A session_sequence=7 end=1 identifier=x",
            "v=1 session_id=A session_sequence=7 identifier=x end=1 end=1",
            "v=1 session_id=A session_sequence=7 identifier=x end=2",
            "v=1 session_id=A session_sequence=7 unknown=1 identifier=x end=1",
            "v=1 session_id=A session_sequence=7 identifier=x identifier=y end=1",
            "v=1 session_id=A session_sequence=7 identifier=x identifier_truncated=1 end=1",
            "v=1 session_id=A session_sequence=7 identifier_truncated=2 identifier=x end=1",
            "v=1 session_id=A session_sequence=7 identifier=a=b end=1",
            // Double space produces an empty token.
            "v=1 session_id=A session_sequence=7  identifier=x end=1",
        ]
        for message in messages {
            let parsed = try #require(Codec.parsed(message, kind: .ui), "lost correlation: \(message)")
            #expect(!parsed.metadataComplete, "unexpectedly complete: \(message)")
            #expect(parsed.optionalFields == nil)
            #expect(parsed.sessionId == "A")
            #expect(parsed.sessionSequence == 7)
            #expect(Codec.strictlyParsed(message, kind: .ui) == nil)
        }
    }

    @Test func apiTailValidationCoversEventSpecificRules() throws {
        let invalidTails = [
            "v=1 session_id=A session_sequence=7 method=GET status=200 end=1",
            "v=1 session_id=A session_sequence=7 duration_ms=-1 end=1",
            "v=1 session_id=A session_sequence=7 duration_ms=604800001 end=1",
            "v=1 session_id=A session_sequence=7 status=200 method=GET duration_ms=1 end=1",
            "v=1 session_id=A session_sequence=7 duration_ms=1 method=GET end=1",
            "v=1 session_id=A session_sequence=7 duration_ms=1 identifier_truncated=1 end=1",
            "v=1 session_id=A session_sequence=7 method=\(String(repeating: "M", count: 33)) duration_ms=1 end=1",
        ]
        for message in invalidTails {
            let parsed = try #require(Codec.parsed(message, kind: .api))
            #expect(!parsed.metadataComplete, "unexpectedly complete: \(message)")
        }

        let uiWithoutIdentifier = "v=1 session_id=A session_sequence=7 end=1"
        #expect(Codec.parsed(uiWithoutIdentifier, kind: .ui)?.metadataComplete == false)
    }

    @Test func truncatedSignpostMessagesStillDecodeTheirCorrelation() throws {
        let identifier = String(repeating: "茶", count: 300)
        let message = try #require(ui(sessionId: "session-1", sequence: 118, identifier: identifier))
        let parsed = try #require(Codec.parsed(message, kind: .ui))
        #expect(parsed.metadataComplete)
        #expect(parsed.sessionId == "session-1")
        #expect(parsed.sessionSequence == 118)
        #expect(parsed.optionalFields?.identifierTruncated == true)
        let prefix = try #require(parsed.optionalFields?.identifier)
        #expect(identifier.hasPrefix(prefix))
    }
}
