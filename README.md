# tokiwatari-ios-sdk

Record an iOS app's UI events and API traffic into a single SQLite timeline, searched with the companion [`tokiwatari-cli`](https://github.com/mii-chan/tokiwatari-cli). The SDK is the sole writer of the database — the CLI reads it read-only.

## Requirements

- iOS 18+ / macOS 15+
- Swift 6.0+

## Installation

Add the package with Swift Package Manager and link the `Tokiwatari` library:

```swift
.package(url: "https://github.com/mii-chan/tokiwatari-ios-sdk.git", from: "0.1.0"),
```

## Setup

Call `configure` once at launch, from the build configurations that should log:

```swift
#if DEBUG
Tokiwatari.configure()
#endif
```

All parameters are optional:

```swift
Tokiwatari.configure(
    session: TokiwatariLogSession(),          // session provider (see below)
    retentionSessions: 10,                    // keep the newest N sessions
    underlyingURLProtocols: [],               // mock hook for tests/playgrounds
    additionalSensitiveHeaderNames: ["X-Session-Token"],
    additionalSensitiveBodyKeys: ["session_key"]
)
```

Logging is compiled in only when this package is built with DEBUG; otherwise every call is a no-op, `configure` prints a warning, and `Tokiwatari.isActive` stays `false`.

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

`identifier` is the search key (`tokiwatari ui --like 'tea_tapped_%'`); it is also a good fit for the view's `accessibilityIdentifier`.

Modules that only define events can depend on the dependency-free `TokiwatariTracking` product alone (`import TokiwatariTracking`) instead of the full SDK.

## Recording API traffic

Requests through `URLSession.shared` are logged automatically after `configure` (via `URLProtocol.registerClass`). For sessions built from a custom configuration, opt in explicitly:

```swift
let configuration = URLSessionConfiguration.default
Tokiwatari.enableAPILogging(in: configuration)
let session = URLSession(configuration: configuration)
```

Each request becomes one timeline row with method, URL, status code, duration, and redacted headers/body excerpts (64KB per side).

### GraphQL

Requests whose JSON body has a string `query` field get a logical identifier derived from the operation — `GraphQL:Query:GetUser`, `GraphQL:Mutation:AddFavorite` (`GraphQL:Query` for anonymous operations) — searchable with `tokiwatari api --like 'GraphQL:%'`.

### Redaction

Values are stored as `<redacted>` for:

- **Headers** (case-insensitive): Authorization, Proxy-Authorization, WWW-Authenticate, Cookie, Set-Cookie, X-API-Key, X-Auth-Token.
- **JSON body keys**, recursively through nested objects and arrays; matching ignores case and `_`/`-` (so `access_token`, `accessToken` and `ACCESS-TOKEN` all match): password, passcode, secret, token, access_token, refresh_token, id_token, api_key, client_secret, authorization.

Both sets can be extended (never shrunk) via `configure(additionalSensitiveHeaderNames:additionalSensitiveBodyKeys:)`. Redaction runs on the full body before the 64KB excerpt; bodies without sensitive keys are stored byte-for-byte.

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

## Storage details

- Database: `Library/Application Support/tokiwatari_debug_events.sqlite` (WAL mode). The schema is the single contract with `tokiwatari-cli`; its canonical definition lives in that repository (`skills/tokiwatari/references/schema.md`) and is verified via `PRAGMA user_version`.
- On a `user_version` mismatch (SDK upgrade or downgrade) the database is dropped and recreated — debug logs are disposable, there are no migrations.
- Retention: at `configure` time, all but the newest `retentionSessions` sessions are deleted.
- The WAL is checkpointed (`TRUNCATE`) on background transitions and every 30 seconds, keeping snapshot copies consistent.
- Inserts are asynchronous; logging never blocks the main thread.

## Development

```bash
swift build && swift test    # runs on a macOS host
swift build -c release      # verifies the Release no-op path compiles
```

## License

[MIT License](LICENSE.txt)

This package depends on [GRDB.swift](https://github.com/groue/GRDB.swift) (MIT License).
