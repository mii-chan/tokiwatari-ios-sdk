import Foundation
import Testing
@testable import Tokiwatari

@Suite(.serialized) struct BodyCaptureExtensionTests {

    private let bom: [UInt8] = [0xEF, 0xBB, 0xBF]

    @Test func parsesBOMPrefixedJSONBodies() throws {
        let json = #"{"password":"hunter2","tea":"sencha"}"#
        let events = try recordedEvents {
            Tokiwatari.logAPIEvent(
                request: makeRequest(
                    method: "POST",
                    body: Data(bom) + Data(json.utf8),
                    contentType: "application/json"
                ),
                start: Date(),
                end: Date()
            )
        }
        let event = try #require(events.first)
        #expect(event["request", "body", "password"] as? String == "<redacted>")
        #expect(event["request", "body", "tea"] as? String == "sencha")
    }

    @Test func recognizesBOMAndWhitespacePrefixedJSONWithoutContentType() throws {
        let body = Data(bom) + Data("  \n\t {\"password\":\"x\",\"a\":1}".utf8)
        let events = try recordedEvents {
            Tokiwatari.logAPIEvent(
                request: makeRequest(method: "POST", body: body),
                start: Date(),
                end: Date()
            )
        }
        let event = try #require(events.first)
        #expect(event["request", "body", "a"] as? Int == 1)
        #expect(event["request", "body", "password"] as? String == "<redacted>")
    }
}
