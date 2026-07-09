import Foundation
import Testing
@testable import Tokiwatari

struct BodyRedactionTests {

    private let defaultKeys: Set<String> = [
        "password", "token", "accesstoken", "secret", "apikey",
    ]

    private func redactedJSON(_ body: String, keys: Set<String>? = nil) throws -> [String: Any]? {
        guard let data = Tokiwatari.redactedJSONBody(Data(body.utf8), sensitiveKeys: keys ?? defaultKeys) else {
            return nil
        }
        return try JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    @Test func redactsTopLevelSensitiveKeys() throws {
        let result = try #require(try redactedJSON(#"{"email":"a@example.com","password":"hunter2"}"#))
        #expect(result["password"] as? String == "<redacted>")
        #expect(result["email"] as? String == "a@example.com")
    }

    @Test func matchingIgnoresCaseUnderscoresAndHyphens() throws {
        let result = try #require(try redactedJSON(
            #"{"Access_Token":"t1","accessToken":"t2","ACCESS-TOKEN":"t3","plain":"keep"}"#
        ))
        #expect(result["Access_Token"] as? String == "<redacted>")
        #expect(result["accessToken"] as? String == "<redacted>")
        #expect(result["ACCESS-TOKEN"] as? String == "<redacted>")
        #expect(result["plain"] as? String == "keep")
    }

    @Test func redactsNestedObjectsAndArrays() throws {
        let body = #"{"user":{"name":"testuser","password":"p"},"teas":[{"token":"t","id":1}]}"#
        let result = try #require(try redactedJSON(body))
        let user = try #require(result["user"] as? [String: Any])
        #expect(user["password"] as? String == "<redacted>")
        #expect(user["name"] as? String == "testuser")
        let tea = try #require((result["teas"] as? [[String: Any]])?.first)
        #expect(tea["token"] as? String == "<redacted>")
        #expect(tea["id"] as? Int == 1)
    }

    @Test func redactsWholeNestedValueOfASensitiveKey() throws {
        let result = try #require(try redactedJSON(#"{"secret":{"inner":"x"},"apiKey":42}"#))
        #expect(result["secret"] as? String == "<redacted>")
        #expect(result["apiKey"] as? String == "<redacted>")
    }

    @Test func untouchedWhenNoSensitiveKeyOrNotJSON() {
        #expect(Tokiwatari.redactedJSONBody(Data(#"{"tea_id":42}"#.utf8), sensitiveKeys: defaultKeys) == nil)
        #expect(Tokiwatari.redactedJSONBody(Data("plain text".utf8), sensitiveKeys: defaultKeys) == nil)
        #expect(Tokiwatari.redactedJSONBody(Data("password=hunter2".utf8), sensitiveKeys: defaultKeys) == nil)
    }

    @Test func redactionRunsBeforeTheExcerptLimit() {
        // A body over 64KB still gets its sensitive keys redacted: redaction
        // parses the full body, truncation happens afterwards. The padding key
        // sorts after "password" so the redacted key stays inside the excerpt.
        let padding = String(repeating: "a", count: 70 * 1024)
        let body = #"{"password":"hunter2","z_padding":"\#(padding)"}"#
        let (text, isTruncated) = Tokiwatari.redactedBodyExcerpt(Data(body.utf8), sensitiveKeys: defaultKeys)
        #expect(isTruncated)
        #expect(text.contains(#""password":"<redacted>""#))
        #expect(!text.contains("hunter2"))
    }

    @Test func customKeysExtendTheSet() throws {
        let keys = defaultKeys.union([Tokiwatari.normalizedBodyKey("session_token")])
        let result = try #require(try redactedJSON(#"{"sessionToken":"s","password":"p"}"#, keys: keys))
        #expect(result["sessionToken"] as? String == "<redacted>")
        #expect(result["password"] as? String == "<redacted>")
    }
}
