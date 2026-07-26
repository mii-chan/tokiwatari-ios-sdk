# tokiwatari-ios-sdk

Record an iOS app's UI events and API traffic into a single SQLite timeline, searched with the companion [`tokiwatari-cli`](https://github.com/mii-chan/tokiwatari-cli). The SDK is the sole writer of the database — the CLI reads it read-only.

**Only the traffic you explicitly wire is recorded.** There is no automatic capture: you call `Tokiwatari.logAPIEvent` from your own network layer, and requests you don't wire never appear in the log.

## Requirements

- iOS 18+ / macOS 15+
- Swift 6.0+

## Installation

Add the package with Swift Package Manager and link the `Tokiwatari` library:

```swift
.package(url: "https://github.com/mii-chan/tokiwatari-ios-sdk.git", from: "0.4.0"),
```

## Setup

Call `configure` once at launch:

```swift
Tokiwatari.configure()
```

All parameters are optional:

```swift
Tokiwatari.configure(
    session: TokiwatariLogSession(),                  // session provider (see below)
    allowedQueryParameters: ["page"],                 // URL query values to keep as-is
    retentionSessions: 10,                            // keep the newest N sessions
    maximumMainDatabaseSizeBytes: 128 * 1024 * 1024,  // main DB page-count cap
    maximumRetainedWALSizeBytes: 16 * 1024 * 1024,    // WAL size target
    additionalSensitiveHeaderNames: ["X-Tea-Secret"],
    additionalSensitiveBodyKeys: ["loginCode", "magicLink"]
)
```

Never allowlist authentication or signature query parameters. `maximumMainDatabaseSizeBytes` caps the main SQLite file's page count — it is not a hard cap on total disk usage (WAL/SHM/temporary files and exports are not included).

`configure` never throws. If storage cannot be opened or any `additionalSensitive*` entry is invalid — empty, longer than 256 UTF-8 bytes, or more than 256 distinct entries per list after normalization — the whole call fails: the SDK stays inactive (`Tokiwatari.isActive == false`), events are dropped, a console diagnostic is printed and a DEBUG assertion is raised. Failing beats silently weakening redaction. Invalid `allowedQueryParameters` entries are merely dropped, since that direction only increases redaction.

Logging is compiled in only when this package is built with DEBUG; otherwise every public call is a no-op with no side effects — no files, timers or observers are created, `configure` prints a warning, and `Tokiwatari.isActive` stays `false`.

## Recording API traffic

Wrap your request path and call `logAPIEvent` next to the actual transfer:

```swift
let start = Date()
let (data, response) = try await session.data(for: request)
Tokiwatari.logAPIEvent(
    identifier: "list_teas",              // optional search key — NOT redacted
    request: request,
    response: response as? HTTPURLResponse,
    responseBody: data,
    start: start,
    end: Date()
)
```

Each call becomes one timeline row with method, sanitized URL, status code, duration, and redacted headers/bodies. Ready-made wiring:

- [URLSession recipe](docs/recipes/urlsession.md)
- [Apollo iOS interceptor recipe](docs/recipes/apollo-interceptor.md)

`identifier` is the search key (`tokiwatari api --like 'list_%'`) and is stored **without redaction** — never interpolate secrets or personal data into it. The same applies to UI event identifiers.

### GraphQL and the `query` field

There is no GraphQL flag — one rule covers every request: the **top-level string `query` of a JSON request body is always stored as `"<omitted>"`**, for a single envelope and for each element of a top-level batch array. Secrets inside a query literal cannot be caught by key redaction, so the document is never stored — pass secrets as `variables` instead.

- `operationName` is kept as a search key; `variables` and `extensions` (including APQ's `persistedQuery`) are stored with recursive key redaction, like every other JSON field.
- The omission covers GraphQL-over-HTTP's standard envelope and batch shapes only: `query` strings nested inside custom wrappers (or inside `variables`) are ordinary values and are kept.
- The rule also hits non-GraphQL bodies — a REST `{"query": "search text"}` echo is dropped from the request side. That is the safe direction; response bodies keep their `query` fields.
- GraphQL-over-GET is already covered by URL sanitization: query values are redacted by default, and `variables` are not decoded out of URLs.
- Responses (including `application/graphql-response+json`) are stored as plain JSON with key redaction; note `errors[].message` can contain personal data.

## What is stored — and what never is

Unsupported formats and over-limit data are never stored raw, and built-in plus additionally configured sensitive keys are recursively redacted. Built-in redaction is defense in depth, not a guarantee — always add your app-specific keys (`loginCode`, `magicLink`, `verificationCode`, ...) via `additionalSensitiveBodyKeys`.

### Body capture (allowlist)

| Body | Handling |
| --- | --- |
| `application/json`, `application/*+json` | parsed → top-level `query` omission → recursive key redaction → re-serialized (≤ 64KB, otherwise dropped) |
| No Content-Type | stored only if it fully parses as JSON |
| `application/x-www-form-urlencoded`, `multipart/*`, `text/*`, XML, `application/graphql`, anything else | dropped with a marker |
| Over 1MB, invalid, over depth/node limits, streamed (`httpBodyStream`) | dropped with a marker |

Dropped bodies leave a `{"body_unavailable": <reason>}` marker; raw bytes are never stored as a fallback, and `httpBodyStream` is never read.

### URLs

Query values are stored as `<redacted>` unless allowlisted; userinfo and fragments are stripped; unparseable URLs become `<unavailable>`. URL **paths are not redacted** — never put credentials or secret values in a URL path.

### Redaction defaults

Stored as `<redacted>` (extendable via `configure`, never shrinkable):

- **Headers** (case-insensitive): Authorization, Proxy-Authorization, WWW-Authenticate, Cookie, Set-Cookie, X-API-Key, X-Auth-Token, X-CSRF-Token, X-XSRF-Token, X-Access-Token, X-Refresh-Token, X-Session-Token, X-Client-Secret.
- **Body keys**, recursively; matching ignores case and `_`/`-`: password, passcode, secret, token, access_token, refresh_token, id_token, api_key, client_secret, authorization, otp, one_time_password, pin, pin_code, mfa_code, totp, session_id, session_key, session_token, csrf, csrf_token, xsrf_token, private_key, credential, credentials, auth, bearer_token, card_number, pan, security_code, cvv, cvc.

The same key redaction applies to UI event parameters.

### Size bounds

Everything stored is bounded: identifiers 512B, URLs 8KB, header values 4KB (100 fields / 32KB per side), bodies 64KB each, whole payload 256KB (degrades in stages, keeping the method/URL/status columns), JSON depth 64 / 10,000 nodes, errors as `{"domain", "code"}` only.

## Recording UI events

Convert your analytics event types to `TokiwatariEvent` and log them from your analytics wrapper, next to the real analytics call:

```swift
import Tokiwatari

struct TeaTappedEvent {
    let teaId: Int
    var tokiwatariEvent: TokiwatariEvent {
        TokiwatariEvent(identifier: "tea_tapped_\(teaId)", parameters: ["tea_id": teaId])
    }
}

func track(_ event: TeaTappedEvent) {
    // ... your real analytics send goes here ...
    Tokiwatari.log(event.tokiwatariEvent)   // no-op in Release
}
```

For one-off events there is a shorthand overload:

```swift
Tokiwatari.log(identifier: "tea_tapped_42", parameters: ["tea_id": 42])
```

Parameters get the same recursive key redaction as API bodies. `identifier` is the search key (`tokiwatari ui --like 'tea_tapped_%'`); it is also a good fit for the view's `accessibilityIdentifier`.

Modules that only define events can depend on the dependency-free `TokiwatariTracking` product alone (`import TokiwatariTracking`) instead of the full SDK.

## Sessions

Events are ordered by a per-session, strictly monotonic sequence — never by wall-clock time. The default `TokiwatariLogSession` starts a new session at app launch and after 30 minutes of inactivity when returning to the foreground.

For custom boundaries (e.g. login-based sessions), implement `TokiwatariSessionProviding` and pass it to `configure`. Implementations must be thread-safe, return strictly increasing sequences within a session, and be shared by all loggers — the SDK asserts monotonicity in DEBUG.

## Exporting from a physical device

For devices where a direct pull is not possible, add a debug-menu action:

```swift
let url = try Tokiwatari.exportSnapshot()   // consistent single-file copy (VACUUM INTO)
// present a share sheet / ShareLink with `url`, AirDrop it to your Mac,
// then read it with: tokiwatari --db <path>
```

Exports land in `tmp/TokiwatariExports/tokiwatari-<UUID>.sqlite`. Files older than 24 hours are deleted best-effort at the next cleanup opportunity — the next `configure`, export, periodic maintenance pass, or background transition. There is no strict TTL while the app is suspended; iOS may also clear `tmp/` on its own.

## Storage details

- Database: `Library/Application Support/Tokiwatari/tokiwatari_debug_events.sqlite` (WAL mode), with `.completeUntilFirstUserAuthentication` file protection and backup exclusion. The schema is the single contract with `tokiwatari-cli`; its canonical definition lives in that repository and is verified via `PRAGMA user_version`.
- On a `user_version` mismatch (SDK upgrade or downgrade) the database is dropped and recreated — debug logs are disposable, there are no migrations. Deletion is verified; if any file survives, initialization fails and the SDK stays inactive rather than re-stamping old data with the current version.
- Size caps: `max_page_count` and `journal_size_limit` are applied on the writer with their effective values verified. An existing larger database stops growing rather than shrinking. `max_page_count` does not prevent temporary WAL growth.
- Maintenance every 30 seconds: expired exports are removed and sessions beyond `retentionSessions` are purged; the WAL is checkpointed passively above 1MB and truncated only above `maximumRetainedWALSizeBytes` (plus best-effort truncation on background transitions and before exports).
- On `SQLITE_FULL` the SDK purges the oldest completed session, then the current session's oldest events, retrying the insert at most twice before dropping it.
- Inserts are asynchronous and fully sanitized before they reach the writer queue; logging never blocks the main thread.

## Development

```bash
swift build && swift test                         # runs on a macOS host
swift build -c release && swift test -c release   # verifies the Release no-op contract
```

## License

[MIT License](LICENSE.txt)

This package depends on [GRDB.swift](https://github.com/groue/GRDB.swift) (MIT License).
