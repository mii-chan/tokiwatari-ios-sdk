import Foundation
import Testing
@testable import Tokiwatari

@Suite(.serialized) struct APIEventLoggingTests {

    private let start = Date(timeIntervalSince1970: 1_700_000_000)
    private var end: Date { start.addingTimeInterval(1.5) }

    @Test func basicRecordStoresBoundedColumns() throws {
        let events = try recordedEvents(allowedQueryParameters: ["page"]) {
            Tokiwatari.logAPIEvent(
                identifier: "list_teas",
                request: makeRequest("https://api.tokiwatari.test/v1/teas?page=2&token=sekrit"),
                response: makeResponse(),
                start: start,
                end: end
            )
        }
        let event = try #require(events.first)
        #expect(event.eventKind == "api")
        #expect(event.identifier == "list_teas")
        #expect(event.httpMethod == "GET")
        #expect(event.statusCode == 200)
        #expect(event.durationMs == 1500)
        let url = try #require(event.url)
        #expect(url.contains("page=2"))
        #expect(!url.contains("sekrit"))
    }

    @Test func redactsHeadersAndJSONBodiesOnBothSides() throws {
        let requestBody = #"{"email":"a@example.com","password":"hunter2","nested":{"api_key":"k1"}}"#
        let events = try recordedEvents(
            additionalSensitiveHeaderNames: ["X-Tea-Secret"],
            additionalSensitiveBodyKeys: ["teaCode"]
        ) {
            Tokiwatari.logAPIEvent(
                request: makeRequest(
                    method: "POST",
                    headers: ["Authorization": "Bearer t", "X-Tea-Secret": "s", "Accept": "application/json"],
                    body: Data(requestBody.utf8),
                    contentType: "application/json"
                ),
                response: makeResponse(headers: ["Set-Cookie": "sid=1"]),
                responseBody: Data(#"{"teaCode":"c-1","name":"sencha"}"#.utf8),
                start: start,
                end: end
            )
        }
        let event = try #require(events.first)
        #expect(event["request", "headers", "Authorization"] as? String == "<redacted>")
        #expect(event["request", "headers", "X-Tea-Secret"] as? String == "<redacted>")
        #expect(event["request", "headers", "Accept"] as? String == "application/json")
        #expect(event["response", "headers", "Set-Cookie"] as? String == "<redacted>")
        #expect(event["request", "body", "password"] as? String == "<redacted>")
        #expect(event["request", "body", "email"] as? String == "a@example.com")
        #expect(event["request", "body", "nested", "api_key"] as? String == "<redacted>")
        #expect(event["response", "body", "teaCode"] as? String == "<redacted>")
        #expect(event["response", "body", "name"] as? String == "sencha")
        #expect(!(event.payloadJson ?? "").contains("hunter2"))
    }

    @Test func graphQLQueryLiteralIsNeverStored() throws {
        let body = """
        {"query":"query Teas($id: ID!) { tea(id: $id) { secretBlendLiteral } }",\
        "operationName":"Teas","variables":{"id":"t-1","token":"sekrit-var"}}
        """
        let events = try recordedEvents {
            Tokiwatari.logAPIEvent(
                request: makeRequest(method: "POST", body: Data(body.utf8), contentType: "application/json"),
                response: makeResponse(),
                start: start,
                end: end
            )
        }
        let event = try #require(events.first)
        #expect(event["request", "body", "query"] as? String == "<omitted>")
        #expect(event["request", "body", "operationName"] as? String == "Teas")
        #expect(event["request", "body", "variables", "id"] as? String == "t-1")
        #expect(event["request", "body", "variables", "token"] as? String == "<redacted>")
        let payload = try #require(event.payloadJson)
        #expect(!payload.contains("secretBlendLiteral"))
        #expect(!payload.contains("sekrit-var"))
    }

    @Test func graphQLAPQWithoutQueryKeepsExtensions() throws {
        let body = #"{"operationName":"Teas","extensions":{"persistedQuery":{"version":1,"sha256Hash":"abc123"}}}"#
        let events = try recordedEvents {
            Tokiwatari.logAPIEvent(
                request: makeRequest(method: "POST", body: Data(body.utf8), contentType: "application/json"),
                start: start,
                end: end
            )
        }
        let event = try #require(events.first)
        #expect(event["request", "body", "query"] == nil)
        #expect(event["request", "body", "operationName"] as? String == "Teas")
        #expect(event["request", "body", "extensions", "persistedQuery", "sha256Hash"] as? String == "abc123")
    }

    @Test func graphQLResponseBodyIsTreatedAsPlainJSON() throws {
        let body = #"{"data":{"tea":{"name":"gyokuro"}},"query":"kept-as-is"}"#
        let events = try recordedEvents {
            Tokiwatari.logAPIEvent(
                request: makeRequest(method: "POST"),
                response: makeResponse(headers: ["Content-Type": "application/graphql-response+json"]),
                responseBody: Data(body.utf8),
                start: start,
                end: end
            )
        }
        let event = try #require(events.first)
        #expect(event["response", "body", "data", "tea", "name"] as? String == "gyokuro")
        #expect(event["response", "body", "query"] as? String == "kept-as-is")
    }

    @Test func omitsQueryButKeepsOtherRequestFields() throws {
        let body = #"{"query":"query Q { queryLiteralXYZ }","variables":{"token":"sekrit"},"debugInfo":"keep-me"}"#
        let events = try recordedEvents {
            Tokiwatari.logAPIEvent(
                request: makeRequest(method: "POST", body: Data(body.utf8), contentType: "application/json"),
                start: start,
                end: end
            )
        }
        let event = try #require(events.first)
        #expect(event["request", "body", "query"] as? String == "<omitted>")
        #expect(event["request", "body", "debugInfo"] as? String == "keep-me")
        #expect(event["request", "body", "variables", "token"] as? String == "<redacted>")
        #expect(!(event.payloadJson ?? "").contains("queryLiteralXYZ"))
    }

    @Test func omitsStringQueryRegardlessOfEnvelopeShape() throws {
        let body = #"{"query":"findTeas","variables":"plain-string"}"#
        let events = try recordedEvents {
            Tokiwatari.logAPIEvent(
                request: makeRequest(method: "POST", body: Data(body.utf8), contentType: "application/json"),
                start: start,
                end: end
            )
        }
        let event = try #require(events.first)
        #expect(event["request", "body", "query"] as? String == "<omitted>")
        #expect(event["request", "body", "variables"] as? String == "plain-string")
    }

    @Test func graphQLBatchOmitsEveryQueryDocument() throws {
        let body = """
        [{"query":"query A { secretLiteralA }","variables":{"token":"sekrit-1"}},\
        {"query":"mutation B { secretLiteralB }","operationName":"B"}]
        """
        let events = try recordedEvents {
            Tokiwatari.logAPIEvent(
                request: makeRequest(method: "POST", body: Data(body.utf8), contentType: "application/json"),
                start: start,
                end: end
            )
        }
        let event = try #require(events.first)
        let elements = try #require(event["request", "body"] as? [[String: Any]])
        #expect(elements.count == 2)
        #expect(elements[0]["query"] as? String == "<omitted>")
        #expect((elements[0]["variables"] as? [String: Any])?["token"] as? String == "<redacted>")
        #expect(elements[1]["query"] as? String == "<omitted>")
        #expect(elements[1]["operationName"] as? String == "B")
        let payload = try #require(event.payloadJson)
        #expect(!payload.contains("secretLiteral"))
        #expect(!payload.contains("sekrit-1"))
    }

    @Test func keepsNonDictionaryArrayBodies() throws {
        let events = try recordedEvents {
            Tokiwatari.logAPIEvent(
                request: makeRequest(method: "POST", body: Data("[1,2,3]".utf8), contentType: "application/json"),
                start: start,
                end: end
            )
            Tokiwatari.logAPIEvent(
                request: makeRequest(
                    method: "POST",
                    body: Data(#"[{"query":"query M { m }"},"plain",7]"#.utf8),
                    contentType: "application/json"
                ),
                start: start,
                end: end
            )
        }
        #expect(events[0]["request", "body"] as? [Int] == [1, 2, 3])
        let mixed = try #require(events[1]["request", "body"] as? [Any])
        #expect((mixed[0] as? [String: Any])?["query"] as? String == "<omitted>")
        #expect(mixed[1] as? String == "plain")
        #expect(mixed[2] as? Int == 7)
    }

    @Test func nestedQueryFieldsAreOutsideTheOmissionScope() throws {
        // Covered scope: the top-level object and top-level batch elements.
        // `query` strings inside custom wrappers or variables are ordinary
        // values — a `variables.query` search string must survive.
        let body = #"{"operations":[{"query":"nested-document"}],"variables":{"query":"search text"}}"#
        let events = try recordedEvents {
            Tokiwatari.logAPIEvent(
                request: makeRequest(method: "POST", body: Data(body.utf8), contentType: "application/json"),
                start: start,
                end: end
            )
        }
        let event = try #require(events.first)
        let operations = try #require(event["request", "body", "operations"] as? [[String: Any]])
        #expect(operations.first?["query"] as? String == "nested-document")
        #expect(event["request", "body", "variables", "query"] as? String == "search text")
    }

    @Test func complexityLimitAppliesAcrossTheWholeBatch() throws {
        // Two elements of ~6,000 nodes each: fine per element, over the limit
        // combined. The node budget is per body, not per batch element.
        let element = #"{"v":[\#(Array(repeating: "0", count: 6000).joined(separator: ","))]}"#
        let events = try recordedEvents {
            Tokiwatari.logAPIEvent(
                request: makeRequest(
                    method: "POST",
                    body: Data("[\(element),\(element)]".utf8),
                    contentType: "application/json"
                ),
                start: start,
                end: end
            )
        }
        let event = try #require(events.first)
        #expect(event["request", "body", "body_unavailable"] as? String == "json_complexity_limit")
    }

    @Test func normalizesContentTypeCaseAndParameters() throws {
        let events = try recordedEvents {
            Tokiwatari.logAPIEvent(
                request: makeRequest(
                    method: "POST",
                    body: Data(#"{"a":1}"#.utf8),
                    contentType: "Application/JSON; charset=UTF-8"
                ),
                start: start,
                end: end
            )
            Tokiwatari.logAPIEvent(
                request: makeRequest(
                    method: "POST",
                    body: Data(#"{"a":1}"#.utf8),
                    contentType: "text/example+json"
                ),
                start: start,
                end: end
            )
            Tokiwatari.logAPIEvent(
                request: makeRequest(
                    method: "POST",
                    body: Data("irrelevant".utf8),
                    contentType: "multipart/form-data; boundary=x"
                ),
                start: start,
                end: end
            )
        }
        #expect(events[0]["request", "body", "a"] as? Int == 1)
        #expect(events[1]["request", "body", "body_unavailable"] as? String == "unsupported_content_type")
        #expect(events[2]["request", "body", "body_unavailable"] as? String == "multipart")
    }

    @Test func doesNotReuseRequestContentTypeForResponseBody() throws {
        let events = try recordedEvents {
            Tokiwatari.logAPIEvent(
                request: makeRequest(method: "POST", body: Data(#"{"a":1}"#.utf8), contentType: "application/json"),
                response: makeResponse(headers: ["Content-Type": "text/plain"]),
                responseBody: Data(#"{"looks":"like-json"}"#.utf8),
                start: start,
                end: end
            )
        }
        let event = try #require(events.first)
        #expect(event["request", "body", "a"] as? Int == 1)
        #expect(event["response", "body", "body_unavailable"] as? String == "unsupported_content_type")
        #expect(!(event.payloadJson ?? "").contains("like-json"))
    }

    @Test func unparseableURLStoresOnlyUnavailableMarker() throws {
        // Invalid scheme: URL(dataRepresentation:) accepts it but URLComponents
        // refuses to parse it.
        let rawURL = try #require(URL(
            dataRepresentation: Data("ht tp://api.tokiwatari.test/sekrit-path?token=sekrit#f".utf8),
            relativeTo: nil
        ))
        let events = try recordedEvents {
            Tokiwatari.logAPIEvent(request: URLRequest(url: rawURL), start: start, end: end)
        }
        let url = try #require(events.first?.url)
        #expect(url == "<unavailable>")
        #expect(!url.contains("sekrit"))
    }

    @Test func lenientlyReparsedURLsStillGetRedacted() throws {
        // The macOS 15 parser percent-encodes many invalid URLs instead of
        // failing; the sanitizer must still strip the fragment and query values.
        let rawURL = try #require(URL(
            dataRepresentation: Data("https://api.tokiwatari.test/pa th?token=sekrit#fr ag".utf8),
            relativeTo: nil
        ))
        let events = try recordedEvents {
            Tokiwatari.logAPIEvent(request: URLRequest(url: rawURL), start: start, end: end)
        }
        let url = try #require(events.first?.url)
        #expect(!url.contains("sekrit"))
        #expect(!url.contains("#"))
    }

    @Test func enforcesProcessingAndStoredBodyLimits() throws {
        let oversizedRaw = Data(count: SanitizationLimits.bodyProcessingByteLimit + 1)
        let oversizedSanitized = #"{"blob":"\#(String(repeating: "a", count: 100_000))"}"#
        let events = try recordedEvents {
            Tokiwatari.logAPIEvent(
                request: makeRequest(method: "POST", body: oversizedRaw, contentType: "application/json"),
                start: start,
                end: end
            )
            Tokiwatari.logAPIEvent(
                request: makeRequest(
                    method: "POST",
                    body: Data(oversizedSanitized.utf8),
                    contentType: "application/json"
                ),
                start: start,
                end: end
            )
        }
        #expect(events[0]["request", "body", "body_unavailable"] as? String == "too_large")
        #expect(events[1]["request", "body", "body_unavailable"] as? String == "sanitized_body_too_large")
        #expect(events[1]["request", "body", "original_bytes"] as? Int == oversizedSanitized.utf8.count)
        #expect(!(events[1].payloadJson ?? "").contains("aaaa"))
    }

    @Test func enforcesJSONDepthLimitOnBodies() throws {
        let depth64 = String(repeating: "[", count: 64) + "1" + String(repeating: "]", count: 64)
        let depth65 = String(repeating: "[", count: 65) + String(repeating: "]", count: 65)
        let events = try recordedEvents {
            for body in [depth64, depth65] {
                Tokiwatari.logAPIEvent(
                    request: makeRequest(method: "POST", body: Data(body.utf8), contentType: "application/json"),
                    start: start,
                    end: end
                )
            }
        }
        #expect(events[0]["request", "body"] != nil)
        #expect(events[0]["request", "body", "body_unavailable"] == nil)
        #expect(events[1]["request", "body", "body_unavailable"] as? String == "json_complexity_limit")
    }

    @Test func neverReadsBodyStreams() throws {
        let stream = InputStream(data: Data("stream-sekrit".utf8))
        var request = makeRequest(method: "POST")
        request.httpBodyStream = stream
        let events = try recordedEvents {
            Tokiwatari.logAPIEvent(request: request, start: start, end: end)
        }
        let event = try #require(events.first)
        #expect(event["request", "body", "body_unavailable"] as? String == "streamed")
        #expect(stream.streamStatus == .notOpen)
        #expect(!(event.payloadJson ?? "").contains("stream-sekrit"))
    }

    @Test func storesErrorsAsBoundedDomainAndCode() throws {
        let urlishError = NSError(domain: "https://evil.example/callback", code: 42)
        let noisyDomain = "com.tokiwatari.\u{07}" + String(repeating: "d", count: 400)
        let noisyError = NSError(domain: noisyDomain, code: 7)
        let events = try recordedEvents {
            Tokiwatari.logAPIEvent(request: makeRequest(), error: urlishError, start: start, end: end)
            Tokiwatari.logAPIEvent(request: makeRequest(), error: noisyError, start: start, end: end)
        }
        #expect(events[0]["error", "domain"] as? String == "<custom-error-domain>")
        #expect(events[0]["error", "code"] as? Int == 42)
        #expect(!(events[0].payloadJson ?? "").contains("evil.example"))
        let storedDomain = try #require(events[1]["error", "domain"] as? String)
        #expect(storedDomain.utf8.count <= SanitizationLimits.errorDomainByteLimit)
        #expect(storedDomain.contains("\u{FFFD}"))
        #expect(storedDomain.hasSuffix("<truncated>"))
        #expect(events[1]["error", "code"] as? Int == 7)
    }

    @Test func boundsMultibyteIdentifiersAndMethods() throws {
        let events = try recordedEvents {
            Tokiwatari.logAPIEvent(
                identifier: String(repeating: "茶", count: 200),
                request: makeRequest(method: "GET" + String(repeating: "X", count: 100)),
                start: start,
                end: end
            )
        }
        let event = try #require(events.first)
        let identifier = try #require(event.identifier)
        #expect(identifier.utf8.count <= SanitizationLimits.identifierByteLimit)
        #expect(identifier.hasSuffix("<truncated>"))
        #expect(!identifier.contains("\u{FFFD}"))
        let method = try #require(event.httpMethod)
        #expect(method.utf8.count <= SanitizationLimits.httpMethodByteLimit)
    }

    @Test func clampsAbnormalDurations() throws {
        let events = try recordedEvents {
            Tokiwatari.logAPIEvent(request: makeRequest(), start: end, end: start) // negative
            Tokiwatari.logAPIEvent(
                request: makeRequest(),
                start: start,
                end: Date(timeIntervalSince1970: 1e18)
            )
        }
        #expect(events[0].durationMs == 0)
        #expect(events[1].durationMs == Int(SanitizationLimits.maximumDurationMilliseconds))
    }

    @Test func degradesOversizedPayloadsInStages() throws {
        let bigBody = #"{"blob":"\#(String(repeating: "b", count: 3000))"}"#
        let events = try recordedEvents(maximumPayloadBytesForTesting: 2500) {
            Tokiwatari.logAPIEvent(
                request: makeRequest(method: "POST", body: Data(#"{"a":1}"#.utf8), contentType: "application/json"),
                response: makeResponse(headers: ["Content-Type": "application/json"]),
                responseBody: Data(bigBody.utf8),
                start: start,
                end: end
            )
        }
        let event = try #require(events.first)
        #expect(event["response", "body", "body_unavailable"] as? String == "event_too_large")
        #expect(event["request", "body", "a"] as? Int == 1)
    }

    @Test func minimalEventStillKeepsIndependentColumns() throws {
        let events = try recordedEvents(maximumPayloadBytesForTesting: 10) {
            Tokiwatari.logAPIEvent(
                request: makeRequest(
                    method: "POST",
                    headers: ["Accept": "application/json"],
                    body: Data(#"{"a":1}"#.utf8),
                    contentType: "application/json"
                ),
                response: makeResponse(statusCode: 201),
                start: start,
                end: end
            )
        }
        let event = try #require(events.first)
        #expect(event["payload_dropped"] as? String == "event_too_large")
        #expect((event["original_bytes"] as? Int ?? 0) > 0)
        #expect(event.httpMethod == "POST")
        #expect(event.statusCode == 201)
        #expect(event.url?.contains("api.tokiwatari.test") == true)
    }

    @Test func uiAndAPIEventsShareSessionAndSequence() throws {
        let events = try recordedEvents {
            Tokiwatari.log(identifier: "tea_tapped")
            Tokiwatari.logAPIEvent(request: makeRequest(), start: start, end: end)
        }
        #expect(events.count == 2)
        #expect(events[0].eventKind == "ui")
        #expect(events[0].sessionSequence == 1)
        #expect(events[1].eventKind == "api")
        #expect(events[1].sessionSequence == 2)
        #expect(events[0].sessionId == events[1].sessionId)
    }
}
