import Foundation
import Testing
@testable import Tokiwatari

@Suite(.serialized) struct DefaultRedactionKeyTests {

    @Test func expandedBodyKeysAreRedactedByDefault() throws {
        let body = """
        {"otp":"123456","one_time_password":"654321","pin":"0000","mfa_code":"m",\
        "session_id":"s","csrf_token":"c","private_key":"p","credentials":"cr",\
        "auth":"a","bearerToken":"b","card_number":"4111111111111111","pan":"4111",\
        "security_code":"999","cvv":"123","cvc":"456","note":"keep-me"}
        """
        let events = try recordedEvents {
            Tokiwatari.logAPIEvent(
                request: makeRequest(method: "POST", body: Data(body.utf8), contentType: "application/json"),
                start: Date(),
                end: Date()
            )
        }
        let event = try #require(events.first)
        for key in [
            "otp", "one_time_password", "pin", "mfa_code", "session_id", "csrf_token",
            "private_key", "credentials", "auth", "bearerToken", "card_number", "pan",
            "security_code", "cvv", "cvc",
        ] {
            #expect(event["request", "body", key] as? String == "<redacted>", "key: \(key)")
        }
        #expect(event["request", "body", "note"] as? String == "keep-me")
        let payload = try #require(event.payloadJson)
        #expect(!payload.contains("123456"))
        #expect(!payload.contains("4111"))
    }

    @Test func expandedHeaderNamesAreRedactedByDefault() throws {
        let events = try recordedEvents {
            Tokiwatari.logAPIEvent(
                request: makeRequest(headers: [
                    "X-CSRF-Token": "c1",
                    "X-XSRF-Token": "c2",
                    "X-Access-Token": "t1",
                    "X-Refresh-Token": "t2",
                    "X-Session-Token": "t3",
                    "X-Client-Secret": "s1",
                    "Accept": "application/json",
                ]),
                start: Date(),
                end: Date()
            )
        }
        let event = try #require(events.first)
        for name in [
            "X-CSRF-Token", "X-XSRF-Token", "X-Access-Token",
            "X-Refresh-Token", "X-Session-Token", "X-Client-Secret",
        ] {
            #expect(event["request", "headers", name] as? String == "<redacted>", "header: \(name)")
        }
        #expect(event["request", "headers", "Accept"] as? String == "application/json")
    }
}
