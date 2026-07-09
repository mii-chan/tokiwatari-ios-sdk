import Foundation
import GRDB
import Testing
@testable import Tokiwatari

/// Mock protocol injected as the *underlying* protocol of TokiwatariURLProtocol's
/// internal session — the whole pipeline runs with zero real networking.
final class MockURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        let (response, data) = handler(request)
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// Uses Tokiwatari's global state → serialized.
@Suite(.serialized) struct URLProtocolLoggingTests {

    private func configureAndMakeSession(
        additionalSensitiveHeaderNames: [String] = [],
        additionalSensitiveBodyKeys: [String] = []
    ) throws -> (TokiwatariDatabase, URLSession) {
        Tokiwatari.configure(
            session: TokiwatariLogSession(),
            retentionSessions: 10,
            underlyingURLProtocols: [MockURLProtocol.self],
            additionalSensitiveHeaderNames: additionalSensitiveHeaderNames,
            additionalSensitiveBodyKeys: additionalSensitiveBodyKeys,
            databaseURL: makeTemporaryDatabaseURL()
        )
        let database = try #require(Tokiwatari.databaseForTesting)

        let configuration = URLSessionConfiguration.ephemeral
        Tokiwatari.enableAPILogging(in: configuration)
        #expect(configuration.protocolClasses?.first == TokiwatariURLProtocol.self)
        return (database, URLSession(configuration: configuration))
    }

    private func fetchOnlyAPIRow(from database: TokiwatariDatabase) throws -> Row {
        try database.flushPendingWrites()
        let rows = try database.pool.read {
            try Row.fetchAll($0, sql: "SELECT * FROM events WHERE event_kind = 'api'")
        }
        #expect(rows.count == 1)
        return try #require(rows.first)
    }

    @Test func isActiveAfterConfigure() throws {
        _ = try configureAndMakeSession()
        #expect(Tokiwatari.isActive)
    }

    @Test func records200ResponseWithRedactedHeaders() async throws {
        let (database, session) = try configureAndMakeSession()
        MockURLProtocol.handler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: [
                    "Content-Type": "application/json",
                    "Set-Cookie": "session=topsecret-cookie",
                ]
            )!
            return (response, Data(#"{"ok":true}"#.utf8))
        }

        var request = URLRequest(url: URL(string: "https://api.example.com/v1/teas?page=1")!)
        request.setValue("Bearer super-secret-token", forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: request)

        // The client still receives the untouched response.
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        #expect(String(decoding: data, as: UTF8.self) == #"{"ok":true}"#)

        let row = try fetchOnlyAPIRow(from: database)
        let method: String? = row["http_method"]
        let url: String? = row["url"]
        let statusCode: Int? = row["status_code"]
        let durationMs: Int? = row["duration_ms"]
        let sequence: Int64 = row["session_sequence"]
        #expect(method == "GET")
        #expect(url == "https://api.example.com/v1/teas?page=1")
        #expect(statusCode == 200)
        #expect(durationMs != nil && durationMs! >= 0)
        #expect(sequence >= 1)

        let payloadJson = try #require(row["payload_json"] as String?)
        #expect(!payloadJson.contains("super-secret-token"))
        #expect(!payloadJson.contains("topsecret-cookie"))

        let payload = try #require(
            try JSONSerialization.jsonObject(with: Data(payloadJson.utf8)) as? [String: Any]
        )
        let requestInfo = try #require(payload["request"] as? [String: Any])
        let requestHeaders = try #require(requestInfo["headers"] as? [String: String])
        #expect(requestHeaders["Authorization"] == "<redacted>")

        let responseInfo = try #require(payload["response"] as? [String: Any])
        #expect(responseInfo["body"] as? String == #"{"ok":true}"#)
        let responseHeaders = try #require(responseInfo["headers"] as? [String: String])
        #expect(responseHeaders["Set-Cookie"] == "<redacted>")
        #expect(responseHeaders["Content-Type"] == "application/json")
    }

    @Test func redactsAdditionalSensitiveHeaders() async throws {
        let (database, session) = try configureAndMakeSession(
            additionalSensitiveHeaderNames: ["X-Session-Token"]
        )
        MockURLProtocol.handler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: [
                    "Content-Type": "application/json",
                    "X-Session-Token": "server-side-secret",
                ]
            )!
            return (response, Data(#"{"ok":true}"#.utf8))
        }

        var request = URLRequest(url: URL(string: "https://api.example.com/v1/me")!)
        // Matching is case-insensitive; built-in names keep working alongside.
        request.setValue("client-side-secret", forHTTPHeaderField: "x-session-token")
        request.setValue("Bearer built-in-secret", forHTTPHeaderField: "Authorization")
        _ = try await session.data(for: request)

        let row = try fetchOnlyAPIRow(from: database)
        let payloadJson = try #require(row["payload_json"] as String?)
        #expect(!payloadJson.contains("client-side-secret"))
        #expect(!payloadJson.contains("server-side-secret"))
        #expect(!payloadJson.contains("built-in-secret"))

        let payload = try #require(
            try JSONSerialization.jsonObject(with: Data(payloadJson.utf8)) as? [String: Any]
        )
        let requestInfo = try #require(payload["request"] as? [String: Any])
        let requestHeaders = try #require(requestInfo["headers"] as? [String: String])
        #expect(requestHeaders["x-session-token"] == "<redacted>")
        #expect(requestHeaders["Authorization"] == "<redacted>")
        let responseInfo = try #require(payload["response"] as? [String: Any])
        let responseHeaders = try #require(responseInfo["headers"] as? [String: String])
        #expect(responseHeaders["X-Session-Token"] == "<redacted>")
        #expect(responseHeaders["Content-Type"] == "application/json")
    }

    @Test func records500ResponseWithRequestBody() async throws {
        let (database, session) = try configureAndMakeSession()
        MockURLProtocol.handler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 500,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, Data(#"{"error":"boom"}"#.utf8))
        }

        var request = URLRequest(url: URL(string: "https://api.example.com/v1/brews")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(#"{"tea_id":42}"#.utf8)
        let (data, response) = try await session.data(for: request)

        #expect((response as? HTTPURLResponse)?.statusCode == 500)
        #expect(String(decoding: data, as: UTF8.self) == #"{"error":"boom"}"#)

        let row = try fetchOnlyAPIRow(from: database)
        let method: String? = row["http_method"]
        let url: String? = row["url"]
        let statusCode: Int? = row["status_code"]
        #expect(method == "POST")
        #expect(url == "https://api.example.com/v1/brews")
        #expect(statusCode == 500)

        let payloadJson = try #require(row["payload_json"] as String?)
        let payload = try #require(
            try JSONSerialization.jsonObject(with: Data(payloadJson.utf8)) as? [String: Any]
        )
        let requestInfo = try #require(payload["request"] as? [String: Any])
        #expect(requestInfo["body"] as? String == #"{"tea_id":42}"#)
        #expect(requestInfo["body_truncated"] == nil)  // under the 64KB limit
        let responseInfo = try #require(payload["response"] as? [String: Any])
        #expect(responseInfo["body"] as? String == #"{"error":"boom"}"#)
    }

    @Test func redactsSensitiveBodyKeysInRequestAndResponse() async throws {
        let (database, session) = try configureAndMakeSession(
            additionalSensitiveBodyKeys: ["session_key"]
        )
        MockURLProtocol.handler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, Data(#"{"sessionKey":"server-secret","user":{"name":"testuser"}}"#.utf8))
        }

        var request = URLRequest(url: URL(string: "https://api.example.com/v1/login")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(#"{"email":"a@example.com","password":"hunter2"}"#.utf8)
        _ = try await session.data(for: request)

        let row = try fetchOnlyAPIRow(from: database)
        let payloadJson = try #require(row["payload_json"] as String?)
        #expect(!payloadJson.contains("hunter2"))
        #expect(!payloadJson.contains("server-secret"))

        let payload = try #require(
            try JSONSerialization.jsonObject(with: Data(payloadJson.utf8)) as? [String: Any]
        )
        let requestBody = try #require((payload["request"] as? [String: Any])?["body"] as? String)
        #expect(requestBody.contains(#""password":"<redacted>""#))
        #expect(requestBody.contains("a@example.com"))  // non-sensitive values survive
        let responseBody = try #require((payload["response"] as? [String: Any])?["body"] as? String)
        #expect(responseBody.contains(#""sessionKey":"<redacted>""#))  // custom key, camelCase form
        #expect(responseBody.contains("testuser"))
    }

    @Test func graphQLQueryGetsOperationIdentifier() async throws {
        let (database, session) = try configureAndMakeSession()
        MockURLProtocol.handler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, Data(#"{"data":{"tea":{"name":"Hojicha"}}}"#.utf8))
        }

        var request = URLRequest(url: URL(string: "https://api.example.com/graphql")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(
            #"{"query":"query GetTea($id: ID!) { tea(id: $id) { name } }","variables":{"id":"42"},"operationName":"GetTea"}"#
                .utf8
        )
        _ = try await session.data(for: request)

        let row = try fetchOnlyAPIRow(from: database)
        let identifier: String? = row["identifier"]
        #expect(identifier == "GraphQL:Query:GetTea")
    }

    @Test func graphQLMutationGetsOperationIdentifier() async throws {
        let (database, session) = try configureAndMakeSession()
        MockURLProtocol.handler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, Data(#"{"data":{"removeItem":{"ok":true}}}"#.utf8))
        }

        var request = URLRequest(url: URL(string: "https://api.example.com/graphql")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(
            #"{"query":"mutation RemoveItem($id: ID!) { removeItem(id: $id) { ok } }","variables":{"id":"42"},"operationName":"RemoveItem"}"#
                .utf8
        )
        _ = try await session.data(for: request)

        let row = try fetchOnlyAPIRow(from: database)
        let identifier: String? = row["identifier"]
        #expect(identifier == "GraphQL:Mutation:RemoveItem")
    }

    @Test func uiEventAndAPIEventShareTheSession() async throws {
        struct TapEvent: TokiwatariTrackable {
            let logIdentifier = "tea_tapped_42"
            let parameters: [String: Any] = ["tea_id": 42]
        }

        let (database, session) = try configureAndMakeSession()
        MockURLProtocol.handler = { request in
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil
            )!
            return (response, Data())
        }

        Tokiwatari.log(TapEvent())
        _ = try await session.data(for: URLRequest(url: URL(string: "https://api.example.com/v1/teas")!))
        try database.flushPendingWrites()

        let rows = try database.pool.read {
            try Row.fetchAll($0, sql: "SELECT * FROM events ORDER BY session_sequence")
        }
        #expect(rows.count == 2)
        let first = try #require(rows.first)
        let last = try #require(rows.last)
        let firstKind: String = first["event_kind"]
        let lastKind: String = last["event_kind"]
        let firstIdentifier: String? = first["identifier"]
        let firstPayload: String? = first["payload_json"]
        let firstSession: String = first["session_id"]
        let lastSession: String = last["session_id"]
        let firstSeq: Int64 = first["session_sequence"]
        let lastSeq: Int64 = last["session_sequence"]

        #expect(firstKind == "ui")
        #expect(firstIdentifier == "tea_tapped_42")
        #expect(firstPayload == #"{"tea_id":42}"#)
        #expect(lastKind == "api")
        #expect(firstSession == lastSession)
        #expect(firstSeq < lastSeq)
    }
}
