#if DEBUG
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

    @Test func legacyDatabaseFilesAreRemovedFromTheSupportDirectory() throws {
        let supportDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tokiwatari-legacy-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: supportDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: supportDirectory) }

        let legacyBase = supportDirectory.appendingPathComponent(TokiwatariDatabase.databaseFileName).path
        for suffix in ["", "-wal", "-shm"] {
            FileManager.default.createFile(atPath: legacyBase + suffix, contents: Data("x".utf8))
        }
        let unrelated = supportDirectory.appendingPathComponent("unrelated.txt")
        FileManager.default.createFile(atPath: unrelated.path, contents: Data("x".utf8))

        try TokiwatariDatabase.removeLegacyDatabase(in: supportDirectory)

        for suffix in ["", "-wal", "-shm"] {
            #expect(!FileManager.default.fileExists(atPath: legacyBase + suffix))
        }
        #expect(FileManager.default.fileExists(atPath: unrelated.path))
    }

    @Test func removingAbsentLegacyFilesIsNotAFailure() throws {
        let emptyDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tokiwatari-legacy-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: emptyDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: emptyDirectory) }

        // Must not throw for the common "nothing to delete" case.
        try TokiwatariDatabase.removeLegacyDatabase(in: emptyDirectory)
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
#endif
