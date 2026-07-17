import Testing
import Foundation
@testable import AnglesiteAppCore
@testable import AnglesiteCore

@Suite("PlistEditorModel crawler policy (#693)")
@MainActor
struct PlistEditorModelCrawlerPolicyTests {
    private static let emptyPlist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict/></plist>
        """

    /// Builds a `PlistEditorModel` against a fresh temp `sourceDirectory` with a minimal
    /// `Info.plist` and, when given, a `.site-config` — `PlistEditorModel.load()` reads both.
    private func makeModel(siteConfig: String? = nil) throws -> PlistEditorModel {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PlistEditorModelCrawlerPolicyTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let plistURL = dir.appendingPathComponent("Info.plist")
        try Self.emptyPlist.write(to: plistURL, atomically: true, encoding: .utf8)
        if let siteConfig {
            try siteConfig.write(to: dir.appendingPathComponent(".site-config"), atomically: true, encoding: .utf8)
        }
        let file = FileRef(url: plistURL, group: .metadata, name: "Info.plist")
        return PlistEditorModel(file: file, websiteTitle: "Test Site", sourceDirectory: dir)
    }

    @Test("load() defaults crawlerPolicySettings when .site-config is absent")
    func loadDefaultsWhenAbsent() async throws {
        let model = try makeModel()
        await model.load()
        #expect(model.crawlerPolicySettings == CrawlerPolicyAsset.Settings())
        #expect(model.isCrawlerPolicyDirty == false)
    }

    @Test("load() populates crawlerPolicySettings from an existing .site-config")
    func loadPopulatesFromExistingConfig() async throws {
        let model = try makeModel(siteConfig: "BLOCK_AI=true\nCONTENT_SIGNALS=search=yes, ai-train=no\n")
        await model.load()
        #expect(model.crawlerPolicySettings.blockAI == true)
        #expect(model.crawlerPolicySettings.search == .yes)
        #expect(model.crawlerPolicySettings.aiInput == .unset)
        #expect(model.crawlerPolicySettings.aiTrain == .no)
        #expect(model.isCrawlerPolicyDirty == false)
    }

    @Test("isCrawlerPolicyDirty flips true after an edit, false after saveCrawlerPolicy, and the write lands on disk")
    func dirtyTrackingAndSave() async throws {
        let model = try makeModel()
        await model.load()
        model.crawlerPolicySettings.blockAI = true
        model.crawlerPolicySettings.aiInput = .no
        #expect(model.isCrawlerPolicyDirty == true)

        let saved = await model.saveCrawlerPolicy()

        #expect(saved == true)
        #expect(model.isCrawlerPolicyDirty == false)
        let config = try String(contentsOf: model.sourceDirectory.appendingPathComponent(".site-config"), encoding: .utf8)
        #expect(CrawlerPolicyAsset.parseSettings(from: config) == model.crawlerPolicySettings)
    }

    @Test("saveCrawlerPolicy no-ops (returns true, doesn't touch disk) when not dirty")
    func saveNoOpsWhenClean() async throws {
        let model = try makeModel()
        await model.load()
        #expect(model.isCrawlerPolicyDirty == false)

        let saved = await model.saveCrawlerPolicy()

        #expect(saved == true)
        #expect(!FileManager.default.fileExists(atPath: model.sourceDirectory.appendingPathComponent(".site-config").path))
    }
}
