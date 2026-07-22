#if !DEBUG
import Foundation
import Testing
import Tokiwatari

/// Verifies the Release contract: the public API exists but is inert — no
/// database, no files, no active state.
@Suite struct ReleaseNoOpTests {

    @Test func publicAPIIsCompletelyInert() throws {
        let supportDirectory = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: false
        )
        let databaseURL = supportDirectory.appendingPathComponent("tokiwatari_debug_events.sqlite")
        let existedBefore = FileManager.default.fileExists(atPath: databaseURL.path)

        Tokiwatari.configure()
        #expect(!Tokiwatari.isActive)

        Tokiwatari.log(identifier: "release_noop", parameters: ["k": "v"])
        Tokiwatari.logAPIEvent(
            identifier: "release_noop_api",
            request: URLRequest(url: URL(string: "https://api.tokiwatari.test")!),
            start: Date(),
            end: Date()
        )

        #expect(FileManager.default.fileExists(atPath: databaseURL.path) == existedBefore)
        #expect(!Tokiwatari.isActive)
        #expect(throws: Tokiwatari.ExportError.self) {
            try Tokiwatari.exportSnapshot()
        }
    }
}
#endif
