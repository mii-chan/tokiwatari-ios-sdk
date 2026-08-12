import Foundation
import Testing
@testable import Tokiwatari

@Suite(.serialized) struct OutputsConfigurationTests {

    @Test func rawValueIsUInt32() {
        #expect(TokiwatariOutputs.RawValue.self == UInt32.self)
        #expect(TokiwatariOutputs.storage.rawValue == 1 << 0)
        #expect(TokiwatariOutputs.signposts.rawValue == 1 << 1)
    }

    @Test func configureDefaultsToStorageOnly() {
        tokiwatariGlobalStateLock.withLock { _ in
            Tokiwatari.configure(session: CountingSession(), databaseURL: makeTemporaryDatabaseURL())
            #expect(Tokiwatari.activeOutputs == [.storage])
            #expect(Tokiwatari.isActive)
        }
    }

    @Test func activeOutputsMirrorSuccessfulInitialization() {
        tokiwatariGlobalStateLock.withLock { _ in
            let cases: [(TokiwatariOutputs, TokiwatariOutputs)] = [
                ([.storage], [.storage]),
                ([.storage, .signposts], [.storage, .signposts]),
                ([.signposts], [.signposts]),
                ([], []),
            ]
            for (requested, expected) in cases {
                Tokiwatari.configure(
                    session: CountingSession(),
                    outputs: requested,
                    signpostEmitterForTesting: FakeSignpostEmitter(),
                    databaseURL: makeTemporaryDatabaseURL()
                )
                #expect(Tokiwatari.activeOutputs == expected)
                #expect(Tokiwatari.isActive == !expected.isEmpty)
                #expect(
                    Tokiwatari.activeOutputs.contains(.storage)
                        == (Tokiwatari.databaseForTesting != nil)
                )
            }
        }
    }

    // MARK: Runtime override

    @Test func runtimeOverrideAddsSignpostsOnlyOnExactMatch() {
        let variable = Tokiwatari.signpostsEnvironmentVariable
        #expect(Tokiwatari.effectiveOutputs(configured: [.storage], environment: [:]) == [.storage])
        #expect(
            Tokiwatari.effectiveOutputs(configured: [.storage], environment: [variable: "1"])
                == [.storage, .signposts]
        )
        #expect(
            Tokiwatari.effectiveOutputs(configured: [], environment: [variable: "1"]) == [.signposts]
        )
        for ignored in ["true", "YES", "0", "", " 1", "1 ", "01"] {
            #expect(
                Tokiwatari.effectiveOutputs(configured: [.storage], environment: [variable: ignored])
                    == [.storage],
                "value \(ignored) must be ignored"
            )
        }
    }

    @Test func unknownRawBitsNeverActivateTheSDK() {
        tokiwatariGlobalStateLock.withLock { _ in
            let unknown = TokiwatariOutputs(rawValue: 1 << 5)

            #expect(Tokiwatari.effectiveOutputs(configured: unknown, environment: [:]) == [])
            #expect(
                Tokiwatari.effectiveOutputs(configured: unknown.union(.storage), environment: [:])
                    == [.storage]
            )
            #expect(
                Tokiwatari.effectiveOutputs(
                    configured: unknown,
                    environment: [Tokiwatari.signpostsEnvironmentVariable: "1"]
                ) == [.signposts]
            )

            Tokiwatari.configure(
                session: CountingSession(),
                outputs: unknown,
                databaseURL: makeTemporaryDatabaseURL()
            )
            #expect(Tokiwatari.activeOutputs == [])
            #expect(!Tokiwatari.isActive)
            #expect(Tokiwatari.databaseForTesting == nil)
        }
    }

    @Test func runtimeOverrideNeverRemovesOutputs() {
        let variable = Tokiwatari.signpostsEnvironmentVariable
        #expect(
            Tokiwatari.effectiveOutputs(
                configured: [.storage, .signposts],
                environment: [variable: "0"]
            ) == [.storage, .signposts]
        )
        #expect(
            Tokiwatari.effectiveOutputs(configured: [.storage, .signposts], environment: [:])
                == [.storage, .signposts]
        )
    }

    @Test func environmentEnablesSignpostsAtConfigureTimeOnly() {
        tokiwatariGlobalStateLock.withLock { _ in
            Tokiwatari.configure(
                session: CountingSession(),
                outputs: [.storage],
                environmentForTesting: [Tokiwatari.signpostsEnvironmentVariable: "1"],
                signpostEmitterForTesting: FakeSignpostEmitter(),
                databaseURL: makeTemporaryDatabaseURL()
            )
            #expect(Tokiwatari.activeOutputs == [.storage, .signposts])

            Tokiwatari.configure(
                session: CountingSession(),
                outputs: [.storage],
                environmentForTesting: [:],
                databaseURL: makeTemporaryDatabaseURL()
            )
            #expect(Tokiwatari.activeOutputs == [.storage])
        }
    }

    // MARK: Failure matrix

    @Test func storageFailureDeactivatesEveryOutput() {
        tokiwatariGlobalStateLock.withLock { _ in
            let blocker = FileManager.default.temporaryDirectory
                .appendingPathComponent("tokiwatari-not-a-directory-\(UUID().uuidString)")
            FileManager.default.createFile(atPath: blocker.path, contents: Data("x".utf8))
            defer { try? FileManager.default.removeItem(at: blocker) }

            Tokiwatari.configure(
                session: CountingSession(),
                outputs: [.storage, .signposts],
                assertingValidity: false,
                signpostEmitterForTesting: FakeSignpostEmitter(),
                databaseURL: blocker.appendingPathComponent("db.sqlite")
            )
            #expect(Tokiwatari.activeOutputs == [])
            #expect(!Tokiwatari.isActive)
            #expect(Tokiwatari.databaseForTesting == nil)
        }
    }

    @Test func invalidSensitiveEntriesFailOnlyStorageRequestingConfigures() {
        tokiwatariGlobalStateLock.withLock { _ in
            let invalidKeys = [String(repeating: "x", count: 300)]

            Tokiwatari.configure(
                session: CountingSession(),
                outputs: [.storage],
                additionalSensitiveBodyKeys: invalidKeys,
                assertingValidity: false,
                databaseURL: makeTemporaryDatabaseURL()
            )
            #expect(Tokiwatari.activeOutputs == [])

            Tokiwatari.configure(
                session: CountingSession(),
                outputs: [.signposts],
                additionalSensitiveBodyKeys: invalidKeys,
                assertingValidity: false,
                signpostEmitterForTesting: FakeSignpostEmitter(),
                databaseURL: makeTemporaryDatabaseURL()
            )
            #expect(Tokiwatari.activeOutputs == [.signposts])
        }
    }

    @Test func signpostsOnlyNeverTouchesTheDatabaseFile() throws {
        try tokiwatariGlobalStateLock.withLock { _ in
            let url = makeTemporaryDatabaseURL()
            Tokiwatari.configure(
                session: CountingSession(),
                outputs: [.signposts],
                signpostEmitterForTesting: FakeSignpostEmitter(),
                databaseURL: url
            )
            Tokiwatari.log(identifier: "no_storage")
            #expect(Tokiwatari.databaseForTesting == nil)
            #expect(!FileManager.default.fileExists(atPath: url.path))

            _ = try #require(throws: Tokiwatari.ExportError.self) {
                try Tokiwatari.exportSnapshot()
            }
        }
    }

    // MARK: Export

    @Test func exportRequiresActiveStorage() throws {
        try tokiwatariGlobalStateLock.withLock { _ in
            for outputs in [TokiwatariOutputs.signposts, []] {
                Tokiwatari.configure(
                    session: CountingSession(),
                    outputs: outputs,
                    signpostEmitterForTesting: FakeSignpostEmitter(),
                    databaseURL: makeTemporaryDatabaseURL()
                )
                do {
                    _ = try Tokiwatari.exportSnapshot()
                    Issue.record("export must fail without active storage")
                } catch Tokiwatari.ExportError.storageNotActive {}
            }

            Tokiwatari.configure(session: CountingSession(), databaseURL: makeTemporaryDatabaseURL())
            let exported = try Tokiwatari.exportSnapshot()
            defer { try? FileManager.default.removeItem(at: exported) }
            #expect(FileManager.default.fileExists(atPath: exported.path))
        }
    }
}
