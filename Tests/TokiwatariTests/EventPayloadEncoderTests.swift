#if DEBUG
import Foundation
import Testing
@testable import Tokiwatari

@Suite struct EventPayloadEncoderTests {

    private func makeComponents() -> EventPayloadEncoder.Components {
        EventPayloadEncoder.Components(
            requestHeaders: ["X-Request": "rh"],
            requestBody: ["request_blob": String(repeating: "a", count: 500)],
            responseHeaders: ["X-Response": "sh"],
            responseBody: ["response_blob": String(repeating: "b", count: 500)],
            error: nil
        )
    }

    @Test func emptyComponentsEncodeToNil() {
        #expect(EventPayloadEncoder.encodedPayload(EventPayloadEncoder.Components(
            requestHeaders: nil, requestBody: nil, responseHeaders: nil, responseBody: nil, error: nil
        )) == nil)
    }

    @Test func payloadWithinTheLimitIsUntouched() throws {
        let payload = try #require(EventPayloadEncoder.encodedPayload(makeComponents()))
        #expect(payload.contains("request_blob"))
        #expect(payload.contains("response_blob"))
    }

    @Test func degradationDropsResponseBodyFirst() throws {
        let payload = try #require(
            EventPayloadEncoder.encodedPayload(makeComponents(), maximumPayloadBytes: 700)
        )
        #expect(payload.contains(#""request_blob""#))
        #expect(!payload.contains(#""response_blob""#))
        #expect(payload.contains(#""body_unavailable":"event_too_large""#))
        #expect(payload.contains("X-Request"))
        #expect(payload.contains("X-Response"))
    }

    @Test func degradationDropsBothBodiesBeforeHeaders() throws {
        let payload = try #require(
            EventPayloadEncoder.encodedPayload(makeComponents(), maximumPayloadBytes: 200)
        )
        #expect(!payload.contains(#""request_blob""#))
        #expect(!payload.contains(#""response_blob""#))
        #expect(payload.contains("X-Request"))
        #expect(payload.contains("X-Response"))
    }

    @Test func degradationDropsResponseHeadersBeforeRequestHeaders() throws {
        let payload = try #require(
            EventPayloadEncoder.encodedPayload(makeComponents(), maximumPayloadBytes: 160)
        )
        #expect(payload.contains("X-Request"))
        #expect(!payload.contains("X-Response"))
    }

    @Test func fullDegradationLeavesMinimalMarkerWithOriginalBytes() throws {
        let payload = try #require(
            EventPayloadEncoder.encodedPayload(makeComponents(), maximumPayloadBytes: 10)
        )
        let object = try #require(
            try JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any]
        )
        #expect(object["payload_dropped"] as? String == "event_too_large")
        #expect((object["original_bytes"] as? Int ?? 0) > 1000)
        #expect(object.count == 2)
    }
}
#endif
