import Foundation
import Testing
@testable import Tokiwatari

@Suite(.serialized) struct UIEventTests {

    @Test func redactsAndConvertsParameters() throws {
        let events = try recordedEvents {
            Tokiwatari.log(identifier: "tea_brewed", parameters: [
                "password": "hunter2",
                "tea_id": 42,
                "steeped": true,
                "when": Date(timeIntervalSince1970: 0),
                "link": URL(string: "https://tokiwatari.test/tea?token=sekrit")!,
                "object": NSObject(),
                "nan": Double.nan,
            ])
        }
        let event = try #require(events.first)
        #expect(event.identifier == "tea_brewed")
        #expect(event["password"] as? String == "<redacted>")
        #expect(event["tea_id"] as? Int == 42)
        #expect(event["steeped"] as? Bool == true)
        #expect(event["when"] as? String == "1970-01-01T00:00:00Z")
        let link = try #require(event["link"] as? String)
        #expect(!link.contains("sekrit"))
        #expect(event["object"] as? String == "<unsupported>")
        #expect(event["nan"] as? String == "<unsupported>")
        #expect(!(event.payloadJson ?? "").contains("hunter2"))
    }

    @Test func cyclicParametersDropTheWholePayload() throws {
        let cyclic = NSMutableDictionary()
        cyclic["self"] = cyclic
        let events = try recordedEvents {
            Tokiwatari.log(identifier: "cyclic_event", parameters: ["params": cyclic, "kept": "no"])
        }
        let event = try #require(events.first)
        #expect(event.payload.count == 1)
        #expect(event["payload_dropped"] as? String == "invalid_or_cyclic_parameters")
        #expect(event.identifier == "cyclic_event")
    }

    @Test func oversizedParametersDropThePayloadButKeepTheIdentifier() throws {
        let events = try recordedEvents {
            Tokiwatari.log(identifier: "big_event", parameters: [
                "blob": String(repeating: "x", count: 70 * 1024),
            ])
        }
        let event = try #require(events.first)
        #expect(event["payload_dropped"] as? String == "payload_too_large")
        #expect((event["original_bytes"] as? Int ?? 0) > SanitizationLimits.maximumUIPayloadBytes)
        #expect(event.identifier == "big_event")
    }

    @Test func boundsUIIdentifiersLikeAPIIdentifiers() throws {
        let events = try recordedEvents {
            Tokiwatari.log(identifier: String(repeating: "茶", count: 200))
        }
        let identifier = try #require(events.first?.identifier)
        #expect(identifier.utf8.count <= SanitizationLimits.identifierByteLimit)
        #expect(identifier.hasSuffix("<truncated>"))
    }
}
