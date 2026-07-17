import Foundation
import Testing
@testable import AnglesiteCore

@Suite("CrawlerPolicyAsset")
struct CrawlerPolicyAssetTests {
    // MARK: parseSettings

    @Test("defaults to blockAI false and every content signal unset when the keys are absent")
    func parseSettingsDefaults() {
        let settings = CrawlerPolicyAsset.parseSettings(from: "SITE_NAME=Acme\n")
        #expect(settings == CrawlerPolicyAsset.Settings())
    }

    @Test("parses BLOCK_AI=true case-insensitively")
    func parseSettingsBlockAI() {
        #expect(CrawlerPolicyAsset.parseSettings(from: "BLOCK_AI=true\n").blockAI == true)
        #expect(CrawlerPolicyAsset.parseSettings(from: "BLOCK_AI=TRUE\n").blockAI == true)
        #expect(CrawlerPolicyAsset.parseSettings(from: "BLOCK_AI=false\n").blockAI == false)
        #expect(CrawlerPolicyAsset.parseSettings(from: "BLOCK_AI=nonsense\n").blockAI == false)
    }

    @Test("parses all three CONTENT_SIGNALS sub-directives")
    func parseSettingsContentSignals() {
        let settings = CrawlerPolicyAsset.parseSettings(
            from: "CONTENT_SIGNALS=search=yes, ai-input=no, ai-train=yes\n"
        )
        #expect(settings.search == .yes)
        #expect(settings.aiInput == .no)
        #expect(settings.aiTrain == .yes)
    }

    @Test("drops unrecognized keys and values, matching edge-artifacts.ts's normalizeContentSignal")
    func parseSettingsDropsUnrecognized() {
        let settings = CrawlerPolicyAsset.parseSettings(
            from: "CONTENT_SIGNALS=search=yes, bogus=yes, ai-train=maybe\n"
        )
        #expect(settings.search == .yes)
        #expect(settings.aiInput == .unset)
        #expect(settings.aiTrain == .unset)
    }

    @Test("a later duplicate key wins, matching edge-artifacts.ts's Map dedup")
    func parseSettingsDedupesLastWins() {
        let settings = CrawlerPolicyAsset.parseSettings(from: "CONTENT_SIGNALS=search=yes, search=no\n")
        #expect(settings.search == .no)
    }

    @Test("ignores commented-out lines")
    func parseSettingsIgnoresComments() {
        let settings = CrawlerPolicyAsset.parseSettings(from: "# BLOCK_AI=true\n")
        #expect(settings.blockAI == false)
    }

    // MARK: install

    private func makeSiteDirectory() throws -> (root: URL, siteDir: URL, fm: FileManager) {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let siteDir = root.appendingPathComponent("Source")
        try fm.createDirectory(at: siteDir, withIntermediateDirectories: true)
        return (root, siteDir, fm)
    }

    @Test("install writes BLOCK_AI and CONTENT_SIGNALS into .site-config")
    func installWritesBothKeys() throws {
        let (root, siteDir, fm) = try makeSiteDirectory()
        defer { try? fm.removeItem(at: root) }
        try "SITE_NAME=Acme\n".write(to: siteDir.appendingPathComponent(".site-config"), atomically: true, encoding: .utf8)

        try CrawlerPolicyAsset.install(
            CrawlerPolicyAsset.Settings(blockAI: true, search: .yes, aiInput: .no, aiTrain: .unset),
            siteDirectory: siteDir,
            fileManager: fm
        )

        let config = try String(contentsOf: siteDir.appendingPathComponent(".site-config"), encoding: .utf8)
        #expect(config.contains("BLOCK_AI=true"))
        #expect(config.contains("CONTENT_SIGNALS=search=yes, ai-input=no"))
        #expect(!config.contains("ai-train"), "an unset sub-directive must not be written at all")
        #expect(config.contains("SITE_NAME=Acme"), "unrelated keys must survive the upsert")
    }

    @Test("install round-trips through parseSettings")
    func installRoundTrips() throws {
        let (root, siteDir, fm) = try makeSiteDirectory()
        defer { try? fm.removeItem(at: root) }

        let settings = CrawlerPolicyAsset.Settings(blockAI: true, search: .no, aiInput: .yes, aiTrain: .no)
        try CrawlerPolicyAsset.install(settings, siteDirectory: siteDir, fileManager: fm)

        let config = try String(contentsOf: siteDir.appendingPathComponent(".site-config"), encoding: .utf8)
        #expect(CrawlerPolicyAsset.parseSettings(from: config) == settings)
    }

    @Test("install with all-unset content signals writes CONTENT_SIGNALS as empty, not omitted")
    func installAllUnsetWritesEmptyValue() throws {
        // edge-artifacts.ts's normalizeContentSignal treats an empty string as falsy (no directive
        // emitted), so writing the key with an empty value is equivalent to "no signals set" on
        // the read side — this just documents that behavior rather than omitting the key.
        let (root, siteDir, fm) = try makeSiteDirectory()
        defer { try? fm.removeItem(at: root) }

        try CrawlerPolicyAsset.install(CrawlerPolicyAsset.Settings(), siteDirectory: siteDir, fileManager: fm)

        let config = try String(contentsOf: siteDir.appendingPathComponent(".site-config"), encoding: .utf8)
        #expect(config.contains("CONTENT_SIGNALS=\n"))
    }
}
