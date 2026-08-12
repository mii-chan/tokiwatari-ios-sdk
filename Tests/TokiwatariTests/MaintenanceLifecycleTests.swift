import Foundation
import Testing
@testable import Tokiwatari

@Suite(.serialized) struct MaintenanceLifecycleTests {

    private func makeExpiredExportFile() throws -> URL {
        let directory = TokiwatariDatabase.exportDirectoryURL()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("tokiwatari-expired-\(UUID().uuidString).sqlite")
        FileManager.default.createFile(atPath: file.path, contents: Data("x".utf8))
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: -TokiwatariDatabase.exportTimeToLive - 60)],
            ofItemAtPath: file.path
        )
        return file
    }

    private func deactivateSDK() {
        Tokiwatari.configure(
            session: CountingSession(),
            additionalSensitiveHeaderNames: [""],
            assertingValidity: false,
            databaseURL: makeTemporaryDatabaseURL()
        )
    }

    @Test func startsInfrastructureExactlyOnce() {
        tokiwatariGlobalStateLock.withLock { _ in
            Tokiwatari.storageMaintenanceStarted.withLock { $0 = false }
            var startCount = 0
            Tokiwatari.startStorageMaintenanceIfNeeded { startCount += 1 }
            Tokiwatari.startStorageMaintenanceIfNeeded { startCount += 1 }
            #expect(startCount == 1)
        }
    }

    @Test func configureStartsMaintenanceOnlyAfterStorageInitializationSucceeds() {
        tokiwatariGlobalStateLock.withLock { _ in
            Tokiwatari.storageMaintenanceStarted.withLock { $0 = false }
            deactivateSDK()
            #expect(Tokiwatari.storageMaintenanceStarted.withLock { !$0 })

            Tokiwatari.configure(session: CountingSession(), databaseURL: makeTemporaryDatabaseURL())
            #expect(Tokiwatari.storageMaintenanceStarted.withLock { $0 })
        }
    }

    @Test func maintenanceHandlersWithoutStorageLeaveExportFilesAlone() throws {
        try tokiwatariGlobalStateLock.withLock { _ in
            deactivateSDK()
            #expect(!Tokiwatari.isActive)

            let expired = try makeExpiredExportFile()
            defer { try? FileManager.default.removeItem(at: expired) }

            Tokiwatari.performDatabaseMaintenance()
            Tokiwatari.performBackgroundCheckpoint()
            #expect(FileManager.default.fileExists(atPath: expired.path))
        }
    }

    @Test func backgroundCheckpointWithActiveStorageCleansUpExpiredExports() throws {
        try tokiwatariGlobalStateLock.withLock { _ in
            Tokiwatari.configure(session: CountingSession(), databaseURL: makeTemporaryDatabaseURL())

            let expired = try makeExpiredExportFile()
            defer { try? FileManager.default.removeItem(at: expired) }

            Tokiwatari.performBackgroundCheckpoint()
            #expect(!FileManager.default.fileExists(atPath: expired.path))
        }
    }

    @Test func signpostsOnlyDefersMaintenanceUntilStorageSucceeds() {
        tokiwatariGlobalStateLock.withLock { _ in
            Tokiwatari.storageMaintenanceStarted.withLock { $0 = false }
            Tokiwatari.configure(
                session: CountingSession(),
                outputs: [.signposts],
                signpostEmitterForTesting: FakeSignpostEmitter(),
                databaseURL: makeTemporaryDatabaseURL()
            )
            #expect(Tokiwatari.storageMaintenanceStarted.withLock { !$0 })

            Tokiwatari.configure(session: CountingSession(), databaseURL: makeTemporaryDatabaseURL())
            #expect(Tokiwatari.storageMaintenanceStarted.withLock { $0 })
        }
    }

    @Test func maintenanceTicksAfterDowngradeToSignpostsOnlyLeaveFilesAlone() throws {
        try tokiwatariGlobalStateLock.withLock { _ in
            Tokiwatari.configure(session: CountingSession(), databaseURL: makeTemporaryDatabaseURL())
            Tokiwatari.configure(
                session: CountingSession(),
                outputs: [.signposts],
                signpostEmitterForTesting: FakeSignpostEmitter(),
                databaseURL: makeTemporaryDatabaseURL()
            )

            let expired = try makeExpiredExportFile()
            defer { try? FileManager.default.removeItem(at: expired) }

            Tokiwatari.performDatabaseMaintenance()
            Tokiwatari.performBackgroundCheckpoint()
            #expect(FileManager.default.fileExists(atPath: expired.path))
        }
    }
}
