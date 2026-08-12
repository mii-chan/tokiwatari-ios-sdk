import Foundation
import Testing
@testable import Tokiwatari

@Suite struct StringSanitizerTests {

    @Test func normalizesControlCharacters() {
        #expect(StringSanitizer.normalizedControlCharacters("a\u{07}b\nc\u{9F}d") == "a\u{FFFD}b\u{FFFD}c\u{FFFD}d")
        #expect(StringSanitizer.normalizedControlCharacters("plain") == "plain")
    }

    @Test func truncatesMultibyteStringsOnCharacterBoundary() {
        let input = String(repeating: "茶", count: 200) // 600 UTF-8 bytes
        let result = StringSanitizer.sanitized(input, maximumBytes: 512)
        #expect(result.utf8.count <= 512)
        #expect(result.hasSuffix(StringSanitizer.truncationMarker))
        #expect(!result.contains("\u{FFFD}"))
    }

    @Test func keepsStringsWithinTheLimitUntouched() {
        let input = String(repeating: "a", count: 512)
        #expect(StringSanitizer.sanitized(input, maximumBytes: 512) == input)
    }
}

@Suite struct URLSanitizerTests {

    @Test func stripsUserinfoAndFragmentAndRedactsQueryValues() throws {
        let url = URL(string: "https://user:pass@api.tokiwatari.test/v1/teas?page=2&token=sekrit&flag#frag")!
        let result = try #require(URLSanitizer.sanitizedString(url, allowedQueryParameters: ["page"]))
        #expect(!result.contains("user"))
        #expect(!result.contains("pass"))
        #expect(!result.contains("frag"))
        #expect(!result.contains("sekrit"))
        #expect(result.contains("page=2"))
        #expect(result.contains("token="))
        #expect(result.contains("flag"))
    }

    @Test func nilURLStaysNil() {
        #expect(URLSanitizer.sanitizedString(nil, allowedQueryParameters: []) == nil)
    }

    @Test func boundsOverlongURLs() throws {
        let url = URL(string: "https://api.tokiwatari.test/" + String(repeating: "p/", count: 8000))!
        let result = try #require(URLSanitizer.sanitizedString(url, allowedQueryParameters: []))
        #expect(result.utf8.count <= SanitizationLimits.sanitizedURLByteLimit)
        #expect(result.hasSuffix(StringSanitizer.truncationMarker))
    }
}

@Suite struct HeaderSanitizerTests {

    private let sensitive: Set<String> = ["authorization", "cookie"]

    @Test func redactsSensitiveNamesCaseInsensitively() {
        let result = HeaderSanitizer.sanitized(
            ["AUTHORIZATION": "Bearer t", "Cookie": "sid=1", "Accept": "application/json"],
            sensitiveNames: sensitive
        )
        #expect(result["AUTHORIZATION"] == "<redacted>")
        #expect(result["Cookie"] == "<redacted>")
        #expect(result["Accept"] == "application/json")
    }

    @Test func matchesSensitivityOnFullNameBeforeTruncation() {
        let longName = "x-" + String(repeating: "s", count: 300)
        let result = HeaderSanitizer.sanitized(
            [longName: "secret-value"],
            sensitiveNames: [longName.lowercased()]
        )
        #expect(result.count == 1)
        let (storedName, storedValue) = result.first!
        #expect(storedName.utf8.count <= SanitizationLimits.headerNameByteLimit)
        #expect(storedName.hasSuffix(StringSanitizer.truncationMarker))
        #expect(storedValue == "<redacted>")
    }

    @Test func boundsValueBytes() {
        let result = HeaderSanitizer.sanitized(
            ["X-Big": String(repeating: "v", count: 5000)],
            sensitiveNames: []
        )
        let value = result["X-Big"]!
        #expect(value.utf8.count <= SanitizationLimits.headerValueByteLimit)
        #expect(value.hasSuffix(StringSanitizer.truncationMarker))
    }

    @Test func keepsAtMostOneHundredHeadersDeterministically() {
        var headers: [String: String] = [:]
        for index in 0..<150 {
            headers[String(format: "h%03d", index)] = "v"
        }
        let result = HeaderSanitizer.sanitized(headers, sensitiveNames: [])
        #expect(result.count == SanitizationLimits.headerCountLimit)
        #expect(result["h000"] == "v")
        #expect(result["h099"] == "v")
        #expect(result["h100"] == nil)
        #expect(result["h149"] == nil)
    }

    @Test func appliesTotalByteBudgetOnStoredSizes() {
        var headers: [String: String] = [:]
        for index in 0..<10 {
            headers[String(format: "h%02d", index)] = String(repeating: "v", count: 4000)
        }
        let result = HeaderSanitizer.sanitized(headers, sensitiveNames: [])
        let totalBytes = result.reduce(0) { $0 + $1.key.utf8.count + $1.value.utf8.count }
        #expect(totalBytes <= SanitizationLimits.allHeadersByteLimit)
        #expect(result.count < 10)
        #expect(result["h00"] != nil)
    }

    @Test func resolvesPostTruncationNameCollisionsFirstWins() {
        let prefix = String(repeating: "p", count: 260)
        let result = HeaderSanitizer.sanitized(
            [prefix + "AAAA": "va", prefix + "BBBB": "vb"],
            sensitiveNames: []
        )
        #expect(result.count == 1)
        #expect(result.values.first == "va")
    }
}

@Suite struct ConfigurationEntriesTests {

    // MARK: Query-parameter allowlist — dropping is the SAFE direction

    @Test func allowlistDropsInvalidEntriesAndDeduplicates() {
        let entries = Tokiwatari.sanitizedAllowedQueryParameters(
            ["page", "page", "", String(repeating: "x", count: 300)],
            assertingValidity: false
        )
        #expect(entries == ["page"])
    }

    @Test func allowlistDropsEntriesBeyondTheCountLimit() {
        let values = (0..<300).map { "key\($0)" }
        let entries = Tokiwatari.sanitizedAllowedQueryParameters(values, assertingValidity: false)
        #expect(entries.count == SanitizationLimits.configurationEntryCountLimit)
    }

    // MARK: Sensitive lists — dropping would WEAKEN redaction, so they throw

    @Test func sensitiveEntriesNormalizeAndDeduplicate() throws {
        let entries = try Tokiwatari.validatedSensitiveEntries(
            ["Access-Token", "access_token"],
            kind: .bodyKey
        ) { Tokiwatari.normalizedBodyKey($0) }
        #expect(entries == ["accesstoken"])
    }

    @Test func sensitiveEntriesRejectEmptyValues() {
        #expect(throws: Tokiwatari.ConfigurationError.self) {
            try Tokiwatari.validatedSensitiveEntries([""], kind: .headerName) { $0.lowercased() }
        }
    }

    @Test func sensitiveEntriesRejectOverLongValues() {
        let overLong = String(repeating: "x", count: SanitizationLimits.configurationEntryByteLimit + 1)
        #expect(throws: Tokiwatari.ConfigurationError.self) {
            try Tokiwatari.validatedSensitiveEntries([overLong], kind: .bodyKey) { $0 }
        }
    }

    @Test func sensitiveEntriesApplyTheCountLimitAfterDeduplication() throws {
        let limit = SanitizationLimits.configurationEntryCountLimit
        // Duplicates collapse back under the limit — accepted.
        let duplicated = (0..<(limit + 50)).map { "key\($0 % limit)" }
        let accepted = try Tokiwatari.validatedSensitiveEntries(duplicated, kind: .bodyKey) { $0 }
        #expect(accepted.count == limit)
        // One extra DISTINCT entry — rejected, never silently ignored.
        let overflowing = (0...limit).map { "key\($0)" }
        #expect(throws: Tokiwatari.ConfigurationError.self) {
            try Tokiwatari.validatedSensitiveEntries(overflowing, kind: .bodyKey) { $0 }
        }
    }
}
