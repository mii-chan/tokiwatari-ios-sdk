#if DEBUG
import Foundation
import Testing
@testable import Tokiwatari

/// Configuration failures must leave the SDK inactive without relying on assertions.
@Suite struct ConfigureFailureTests {

    @Test func overLongSensitiveBodyKeyDeactivatesThePreviouslyActiveSDK() {
        tokiwatariGlobalStateLock.withLock { _ in
            Tokiwatari.configure(
                session: CountingSession(),
                assertingValidity: false,
                databaseURL: makeTemporaryDatabaseURL()
            )
            #expect(Tokiwatari.isActive)

            // A failed re-configure must not leave the previous logger running.
            Tokiwatari.configure(
                session: CountingSession(),
                additionalSensitiveBodyKeys: [String(repeating: "x", count: 300)],
                assertingValidity: false,
                databaseURL: makeTemporaryDatabaseURL()
            )
            #expect(!Tokiwatari.isActive)
            #expect(Tokiwatari.databaseForTesting == nil)
        }
    }

    @Test func emptySensitiveHeaderNameDeactivatesTheSDK() {
        tokiwatariGlobalStateLock.withLock { _ in
            Tokiwatari.configure(
                session: CountingSession(),
                additionalSensitiveHeaderNames: [""],
                assertingValidity: false,
                databaseURL: makeTemporaryDatabaseURL()
            )
            #expect(!Tokiwatari.isActive)
        }
    }

    @Test func tooManySensitiveBodyKeysDeactivateTheSDK() {
        tokiwatariGlobalStateLock.withLock { _ in
            let keys = (0...SanitizationLimits.configurationEntryCountLimit).map { "key\($0)" }
            Tokiwatari.configure(
                session: CountingSession(),
                additionalSensitiveBodyKeys: keys,
                assertingValidity: false,
                databaseURL: makeTemporaryDatabaseURL()
            )
            #expect(!Tokiwatari.isActive)
        }
    }

    @Test func databaseOpenFailureDeactivatesTheSDK() {
        tokiwatariGlobalStateLock.withLock { _ in
            let blocker = FileManager.default.temporaryDirectory
                .appendingPathComponent("tokiwatari-not-a-directory-\(UUID().uuidString)")
            FileManager.default.createFile(atPath: blocker.path, contents: Data("x".utf8))
            defer { try? FileManager.default.removeItem(at: blocker) }

            Tokiwatari.configure(
                session: CountingSession(),
                assertingValidity: false,
                databaseURL: blocker.appendingPathComponent("db.sqlite")
            )
            #expect(!Tokiwatari.isActive)
            #expect(Tokiwatari.databaseForTesting == nil)
        }
    }

    @Test func invalidAllowedQueryParametersDoNotFailConfigure() {
        tokiwatariGlobalStateLock.withLock { _ in
            Tokiwatari.configure(
                session: CountingSession(),
                allowedQueryParameters: ["", "page"],
                assertingValidity: false,
                databaseURL: makeTemporaryDatabaseURL()
            )
            #expect(Tokiwatari.isActive)
        }
    }
}
#endif
