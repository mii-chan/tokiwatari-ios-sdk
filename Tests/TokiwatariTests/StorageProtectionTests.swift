import Foundation
import Testing
@testable import Tokiwatari

@Suite struct StorageProtectionTests {

    @Test func defaultDatabaseURLLivesInTheDedicatedDirectory() throws {
        let url = try TokiwatariDatabase.defaultDatabaseURL()
        #expect(url.lastPathComponent == "tokiwatari_debug_events.sqlite")
        #expect(url.deletingLastPathComponent().lastPathComponent == "Tokiwatari")
    }

    @Test func databaseDirectoryAndFilesAreExcludedFromBackup() throws {
        let url = makeTemporaryDatabaseURL()
        _ = try TokiwatariDatabase(url: url)
        let directoryValues = try url.deletingLastPathComponent()
            .resourceValues(forKeys: [.isExcludedFromBackupKey])
        #expect(directoryValues.isExcludedFromBackup == true)
        let fileValues = try url.resourceValues(forKeys: [.isExcludedFromBackupKey])
        #expect(fileValues.isExcludedFromBackup == true)
    }

    @Test func removeDatabaseFilesPropagatesRemovalErrors() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tokiwatari-reset-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let base = directory.appendingPathComponent(TokiwatariDatabase.databaseFileName)
        FileManager.default.createFile(atPath: base.path, contents: Data("x".utf8))

        struct RemovalDenied: Error {}
        #expect(throws: RemovalDenied.self) {
            try TokiwatariDatabase.removeDatabaseFiles(at: base) { _ in throw RemovalDenied() }
        }
        #expect(FileManager.default.fileExists(atPath: base.path))
    }

    @Test func removeDatabaseFilesFailsWhenAFileSurvivesDeletion() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tokiwatari-reset-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let base = directory.appendingPathComponent(TokiwatariDatabase.databaseFileName)
        FileManager.default.createFile(atPath: base.path, contents: Data("x".utf8))

        // A remover that reports success without removing anything must not
        // pass the read-back verification.
        #expect(throws: TokiwatariDatabase.StorageResetError.self) {
            try TokiwatariDatabase.removeDatabaseFiles(at: base) { _ in }
        }
    }

    @Test func exportsUseUUIDNamesInTheProtectedExportDirectory() throws {
        let database = try makeTemporaryDatabase()
        let url = try database.exportSnapshot()
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(url.deletingLastPathComponent().lastPathComponent == "TokiwatariExports")
        #expect(url.lastPathComponent.hasPrefix("tokiwatari-"))
        #expect(url.pathExtension == "sqlite")
        let directoryValues = try url.deletingLastPathComponent()
            .resourceValues(forKeys: [.isExcludedFromBackupKey])
        #expect(directoryValues.isExcludedFromBackup == true)
        let fileValues = try url.resourceValues(forKeys: [.isExcludedFromBackupKey])
        #expect(fileValues.isExcludedFromBackup == true)
    }

    @Test func expiredExportsAreCleanedUpAfterTheTTL() throws {
        let directory = TokiwatariDatabase.exportDirectoryURL()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let expired = directory.appendingPathComponent("tokiwatari-\(UUID().uuidString).sqlite")
        let fresh = directory.appendingPathComponent("tokiwatari-\(UUID().uuidString).sqlite")
        FileManager.default.createFile(atPath: expired.path, contents: Data("x".utf8))
        FileManager.default.createFile(atPath: fresh.path, contents: Data("x".utf8))
        defer { try? FileManager.default.removeItem(at: fresh) }
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-TokiwatariDatabase.exportTimeToLive - 3600)],
            ofItemAtPath: expired.path
        )

        TokiwatariDatabase.cleanUpExpiredExports()

        #expect(!FileManager.default.fileExists(atPath: expired.path))
        #expect(FileManager.default.fileExists(atPath: fresh.path))
    }

    @Test func periodicMaintenanceRemovesExpiredExports() throws {
        try tokiwatariGlobalStateLock.withLock { _ in
            Tokiwatari.configure(session: CountingSession(), databaseURL: makeTemporaryDatabaseURL())

            let directory = TokiwatariDatabase.exportDirectoryURL()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let expired = directory.appendingPathComponent("tokiwatari-\(UUID().uuidString).sqlite")
            let fresh = directory.appendingPathComponent("tokiwatari-\(UUID().uuidString).sqlite")
            FileManager.default.createFile(atPath: expired.path, contents: Data("x".utf8))
            FileManager.default.createFile(atPath: fresh.path, contents: Data("x".utf8))
            defer { try? FileManager.default.removeItem(at: fresh) }
            try FileManager.default.setAttributes(
                [.modificationDate: Date().addingTimeInterval(-TokiwatariDatabase.exportTimeToLive - 3600)],
                ofItemAtPath: expired.path
            )

            Tokiwatari.performDatabaseMaintenance()

            #expect(!FileManager.default.fileExists(atPath: expired.path))
            #expect(FileManager.default.fileExists(atPath: fresh.path))
        }
    }

    #if os(iOS) && !targetEnvironment(simulator)
    @Test func databaseFilesUseCompleteUntilFirstUserAuthentication() throws {
        let url = makeTemporaryDatabaseURL()
        _ = try TokiwatariDatabase(url: url)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        #expect(
            attributes[.protectionKey] as? FileProtectionType == .completeUntilFirstUserAuthentication
        )
    }
    #endif
}
