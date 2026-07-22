# Recipe: URLSession

Since 0.4.0 the SDK records **only the traffic you explicitly wire** — there is no automatic capture. Wrap your request path once and call `Tokiwatari.logAPIEvent` next to the actual transfer:

```swift
import Tokiwatari

extension URLSession {
    func loggedData(
        for request: URLRequest,
        identifier: String? = nil
    ) async throws -> (Data, URLResponse) {
        let start = Date()
        do {
            let (data, response) = try await data(for: request)
            Tokiwatari.logAPIEvent(
                identifier: identifier,
                request: request,
                response: response as? HTTPURLResponse,
                responseBody: data,
                start: start,
                end: Date()
            )
            return (data, response)
        } catch {
            Tokiwatari.logAPIEvent(
                identifier: identifier,
                request: request,
                error: error,
                start: start,
                end: Date()
            )
            throw error
        }
    }
}
```

Every call is a no-op in Release builds; the wrapper is safe to keep in production code paths.

## What gets stored, what doesn't

- Request bodies are read from `httpBody` only. A `httpBodyStream` is **never read** — the row records `{"body_unavailable": "streamed"}` instead.
- Bodies are captured by Content-Type allowlist (`application/json` and `application/*+json` only). Anything else — including `text/*`, form-urlencoded and multipart — is dropped with a marker, never stored raw.
- The top-level string `query` of a JSON request body — single object or each element of a batch array — is always stored as `"<omitted>"`, GraphQL or not. Response bodies keep their `query` fields.
- URL query values are stored as `<redacted>` unless the parameter name is in `configure(allowedQueryParameters:)`. Fragments and userinfo are stripped.
- URL **paths are not redacted** (they identify the endpoint). Never put tokens or other secrets in a URL path.
- Errors are stored as `{"domain": ..., "code": ...}` only.

## Caution: `identifier` is not redacted

`identifier` is a search key and is stored as-is (bounded and control-character-normalized, but **exempt from redaction**). Use static names like `"list_teas"` — never interpolate secrets or personal data into it.
