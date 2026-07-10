import Testing
@testable import AnglesiteCore

@Suite struct SetupThemeToolTests {
    @Test func replyForSuccessNamesTheTheme() {
        let applied = AppliedDesign(updatedVars: [:], writtenFiles: ["src/styles/global.css"])
        let reply = SetupThemeArguments.reply(for: .success(applied), themeName: "Warm")
        #expect(reply.contains("Warm"))
    }

    @Test func replyForFailureExplainsWhatWentWrong() {
        let reply = SetupThemeArguments.reply(for: .failure(.missingGlobalCSS), themeName: "Warm")
        #expect(!reply.isEmpty)
        #expect(reply != SetupThemeArguments.reply(for: .success(AppliedDesign(updatedVars: [:], writtenFiles: [])), themeName: "Warm"))
    }

    @Test func replyForWriteFailedIncludesMessage() {
        let reply = SetupThemeArguments.reply(
            for: .failure(.writeFailed(message: "disk full", partiallyWritten: [])),
            themeName: "Warm"
        )
        #expect(reply.contains("disk full"))
    }

    @Test func replyForPartialWriteFailureNamesTheFilesAlreadyWritten() {
        let reply = SetupThemeArguments.reply(
            for: .failure(.writeFailed(message: "disk full", partiallyWritten: ["src/styles/global.css"])),
            themeName: "Warm"
        )
        #expect(reply.contains("disk full"))
        #expect(reply.contains("src/styles/global.css"))
        // Must not read like nothing happened — the CSS write already landed on disk.
        #expect(reply.contains("already updated") || reply.contains("mixed state"))
    }

    @Test func replyForMissingRootBlockExplainsWhatWentWrong() {
        let reply = SetupThemeArguments.reply(for: .failure(.missingRootBlock), themeName: "Warm")
        #expect(!reply.isEmpty)
    }
}
