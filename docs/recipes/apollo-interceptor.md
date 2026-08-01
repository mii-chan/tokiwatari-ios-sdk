# Recipe: Apollo iOS interceptor

Records Apollo GraphQL operations with `Tokiwatari.logAPIEvent`.

**Target version**: this recipe is written against the **Apollo iOS 1.x** interceptor API (`ApolloInterceptor` / `ApolloErrorInterceptor` / `InterceptorProvider`). Re-check the interceptor signatures when you adopt a new Apollo major version.

## Recording semantics — read before wiring

- **Unit of recording: one row per HTTP attempt**, not per logical operation. The interceptors sit in the network chain, so Apollo-level retries and the APQ retry each produce their own row. If you need logical-operation granularity, aggregate rows by `identifier` in the CLI instead.
- **Rows record HTTP transfer results, not post-transfer processing.** The record interceptor logs attempts whose transfer completed; `TokiwatariErrorInterceptor` logs attempts that failed **before reaching the record interceptor** (connectivity errors, cancellations — a failed attempt never proceeds past `NetworkFetchInterceptor`). The start-date store is consume-once, so no attempt is recorded twice. Errors raised after a completed transfer (response parsing, cache writes) are NOT reflected in the already-written row — its `error` column stays empty, just like GraphQL `errors[]`.
- **Cache hits are not recorded.** A `.returnCacheDataElseFetch` hit never reaches the network chain, so no row is written. Absence of a row does not mean the operation didn't run.
- **APQ (automatic persisted queries)**: the hash-only attempt has no `query` field; its `extensions.persistedQuery` is stored (recursively redacted). The full-query retry is a second row — the SDK stores its `query` as `"<omitted>"` like any other request.
- **GraphQL errors are not Swift errors.** A response with `errors[]` usually arrives as HTTP 200 and is NOT thrown, so the row's `error` column stays empty — look inside the stored response body. Note `errors[].message` can contain personal data; response bodies get key-based redaction only.
- **Subscriptions are not supported.** WebSocket transport does not go through these interceptors; do not wire them.

## Query documents are never stored

No GraphQL flag is needed: the SDK always stores the top-level string `query` of a JSON request body — single envelope or each element of a batch array — as `"<omitted>"` (secrets inside a query literal cannot be caught by key redaction, so the document is never stored).

- `operationName` is kept as a search key; `variables` / `extensions` are stored with recursive key redaction like any other JSON.
- Consequently: **pass secrets as `variables`, never inline in the query document** — and never in the URL path, which is not redacted.

## Sample interceptors

Three pieces share a consume-once start-date store: one marks the start before the network fetch, one records successful transfers, and the error interceptor records failed attempts.

```swift
import Apollo
import ApolloAPI
import Foundation
import os
import Tokiwatari

final class TokiwatariRequestClock: Sendable {
    private let startDates = OSAllocatedUnfairLock<[ObjectIdentifier: Date]>(uncheckedState: [:])

    func markStart<Operation>(_ request: HTTPRequest<Operation>) {
        startDates.withLockUnchecked { $0[ObjectIdentifier(request)] = Date() }
    }

    /// Consume-once: nil when the other side already took it. Every path must
    /// consume — a leaked entry could later collide with a reused object
    /// identifier and poison another request's duration.
    func takeStart<Operation>(_ request: HTTPRequest<Operation>) -> Date? {
        startDates.withLockUnchecked { $0.removeValue(forKey: ObjectIdentifier(request)) }
    }
}

/// Place BEFORE NetworkFetchInterceptor.
struct TokiwatariStartInterceptor: ApolloInterceptor {
    let id = "tokiwatari.start"
    let clock: TokiwatariRequestClock

    func interceptAsync<Operation: GraphQLOperation>(
        chain: any RequestChain,
        request: HTTPRequest<Operation>,
        response: HTTPResponse<Operation>?,
        completion: @escaping (Result<GraphQLResult<Operation.Data>, any Error>) -> Void
    ) {
        clock.markStart(request)
        chain.proceedAsync(request: request, response: response, interceptor: self, completion: completion)
    }
}

/// Place immediately AFTER NetworkFetchInterceptor (response is populated).
/// Network failures never reach this interceptor — they are recorded by
/// TokiwatariErrorInterceptor instead.
struct TokiwatariRecordInterceptor: ApolloInterceptor {
    let id = "tokiwatari.record"
    let clock: TokiwatariRequestClock

    func interceptAsync<Operation: GraphQLOperation>(
        chain: any RequestChain,
        request: HTTPRequest<Operation>,
        response: HTTPResponse<Operation>?,
        completion: @escaping (Result<GraphQLResult<Operation.Data>, any Error>) -> Void
    ) {
        // Consume first, so the entry cannot leak when toURLRequest() throws.
        let start = clock.takeStart(request)
        if let start, let urlRequest = try? request.toURLRequest() {
            Tokiwatari.logAPIEvent(
                identifier: Operation.operationName,   // NOT redacted — keep it static
                request: urlRequest,
                response: response?.httpResponse,
                responseBody: response?.rawData,
                start: start,
                end: Date()
            )
        }
        chain.proceedAsync(request: request, response: response, interceptor: self, completion: completion)
    }
}

/// Records attempts that fail before reaching the record interceptor
/// (connectivity errors, cancellations, ...). Return it from your
/// InterceptorProvider's `additionalErrorInterceptor(for:)`, sharing the
/// same clock instance.
struct TokiwatariErrorInterceptor: ApolloErrorInterceptor {
    let clock: TokiwatariRequestClock

    func handleErrorAsync<Operation: GraphQLOperation>(
        error: any Error,
        chain: any RequestChain,
        request: HTTPRequest<Operation>,
        response: HTTPResponse<Operation>?,
        completion: @escaping (Result<GraphQLResult<Operation.Data>, any Error>) -> Void
    ) {
        // nil start: the record interceptor already logged this attempt
        // (e.g. a post-transfer parse error) — do not record it twice.
        if let start = clock.takeStart(request),
           let urlRequest = try? request.toURLRequest() {
            Tokiwatari.logAPIEvent(
                identifier: Operation.operationName,
                request: urlRequest,
                response: response?.httpResponse,
                responseBody: response?.rawData,
                error: error,
                start: start,
                end: Date()
            )
        }
        completion(.failure(error))
    }
}
```

Wire the start/record interceptors through a custom `InterceptorProvider` that inserts them around the provider's default network fetch interceptor, and return `TokiwatariErrorInterceptor` from `additionalErrorInterceptor(for:)`.

`identifier` is stored without redaction; the generated `operationName` is a safe static value.
