import Foundation
import Testing
@testable import Tokiwatari

@Suite struct JSONSanitizerTests {

    private let sanitizer = JSONSanitizer(
        sensitiveKeys: ["password", "accesstoken", "token"],
        allowedQueryParameters: []
    )

    private func sanitized(_ value: Any) throws -> Any {
        try sanitizer.sanitized(value)
    }

    @Test func redactsSensitiveKeysRecursively() throws {
        let input: [String: Any] = [
            "user": ["Access_Token": "t", "name": "n"] as [String: Any],
            "list": [["password": "p", "id": 1] as [String: Any]],
            "keep": 1,
        ]
        let result = try #require(try sanitized(input) as? [String: Any])
        let user = try #require(result["user"] as? [String: Any])
        #expect(user["Access_Token"] as? String == "<redacted>")
        #expect(user["name"] as? String == "n")
        let element = try #require((result["list"] as? [[String: Any]])?.first)
        #expect(element["password"] as? String == "<redacted>")
        #expect(element["id"] as? Int == 1)
        #expect(result["keep"] as? Int == 1)
    }

    @Test func redactsWholeSubtreeOfASensitiveKey() throws {
        let result = try #require(try sanitized(["password": ["inner": "x"]]) as? [String: Any])
        #expect(result["password"] as? String == "<redacted>")
    }

    @Test func convertsScalarsToBoundedForms() throws {
        let input: [String: Any] = [
            "text": "hello",
            "flag": true,
            "count": 42,
            "ratio": 1.5,
            "null": NSNull(),
            "when": Date(timeIntervalSince1970: 0),
            "link": URL(string: "https://tokiwatari.test/path?token=sekrit")!,
            "object": NSObject(),
            "nan": Double.nan,
            "infinity": Double.infinity,
        ]
        let result = try #require(try sanitized(input) as? [String: Any])
        #expect(result["text"] as? String == "hello")
        #expect(result["flag"] as? Bool == true)
        #expect(result["count"] as? Int == 42)
        #expect(result["ratio"] as? Double == 1.5)
        #expect(result["null"] is NSNull)
        #expect(result["when"] as? String == "1970-01-01T00:00:00Z")
        let link = try #require(result["link"] as? String)
        #expect(!link.contains("sekrit"))
        #expect(result["object"] as? String == "<unsupported>")
        #expect(result["nan"] as? String == "<unsupported>")
        #expect(result["infinity"] as? String == "<unsupported>")
    }

    @Test func depthSixtyFourSucceedsSixtyFiveFails() throws {
        var ok: Any = "leaf"
        for _ in 0..<63 { ok = [ok] }
        _ = try sanitized([ok]) // 64 nested containers

        var tooDeep: Any = "leaf"
        for _ in 0..<65 { tooDeep = [tooDeep] }
        #expect(throws: JSONSanitizer.SanitizerError.self) {
            _ = try sanitized(tooDeep)
        }
    }

    @Test func nodeCountTenThousandSucceedsOneMoreFails() throws {
        let ok = [Any](repeating: 0, count: SanitizationLimits.maximumJSONNodeCount - 1)
        _ = try sanitized(ok) // root + 9,999 scalars = 10,000 nodes

        let tooMany = [Any](repeating: 0, count: SanitizationLimits.maximumJSONNodeCount)
        #expect(throws: JSONSanitizer.SanitizerError.self) {
            _ = try sanitized(tooMany)
        }
    }

    @Test func cyclicReferenceThrows() {
        let cyclic = NSMutableDictionary()
        cyclic["self"] = cyclic
        #expect(throws: JSONSanitizer.SanitizerError.self) {
            _ = try sanitized(cyclic)
        }
    }

    @Test func queryOmissionCoversTopLevelDictionariesAndBatchElements() {
        let single = BodyCapture.omittingRequestQueryDocument(
            ["query": "query Q { q }", "keep": 1] as [String: Any]
        ) as? [String: Any]
        #expect(single?["query"] as? String == "<omitted>")
        #expect(single?["keep"] as? Int == 1)

        let batch = BodyCapture.omittingRequestQueryDocument(
            [["query": "query A { a }"] as [String: Any], "plain", 7] as [Any]
        ) as? [Any]
        #expect((batch?[0] as? [String: Any])?["query"] as? String == "<omitted>")
        #expect(batch?[1] as? String == "plain")
        #expect(batch?[2] as? Int == 7)

        let nonString = BodyCapture.omittingRequestQueryDocument(
            ["query": ["match": "all"] as [String: Any]] as [String: Any]
        ) as? [String: Any]
        #expect((nonString?["query"] as? [String: Any])?["match"] as? String == "all")
    }
}
