import Foundation
@testable import Tokiwatari

func makeTemporaryDatabaseURL() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("tokiwatari-tests", isDirectory: true)
        .appendingPathComponent(UUID().uuidString + ".sqlite")
}

func makeTemporaryDatabase() throws -> TokiwatariDatabase {
    try TokiwatariDatabase(url: makeTemporaryDatabaseURL())
}

/// The storage format of `timestamp` — part of the contract with the CLI.
func makeContractTimestampFormatter() -> DateFormatter {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(identifier: "UTC")
    formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
    return formatter
}
