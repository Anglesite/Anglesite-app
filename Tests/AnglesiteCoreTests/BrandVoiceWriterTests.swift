// Tests/AnglesiteCoreTests/BrandVoiceWriterTests.swift
import Testing
import Foundation
@testable import AnglesiteCore

/// Covers the single write path (#465) that replaced `SaveBrandVoiceTool`'s direct
/// `ProjectConventionsStore` write — the reviewer's data-loss finding was that a second store
/// instance the shared `ProjectConventionsEngine` never observes could be silently reverted by
/// the next unrelated GUI override write (`ProjectConventionsModel.setOverride` persists the
/// engine's *full* in-memory snapshot). `BrandVoiceWriter` fixes this by always applying through
/// the engine before persisting.
@Suite("BrandVoiceWriter")
struct BrandVoiceWriterTests {
    private func makeConfigDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("brand-voice-writer-\(UUID().uuidString)", isDirectory: true)
    }

    @Test("empty answers write nothing")
    func emptyAnswersWriteNothing() async {
        let engine = ProjectConventionsEngine()
        let configDirectory = makeConfigDirectory()
        let store = ProjectConventionsStore(configDirectory: configDirectory)
        let answers = BrandVoiceAnswers(audience: "", toneWords: [], brandTerms: [], avoidPhrases: [])

        let saved = await BrandVoiceWriter.save(answers, engine: engine, store: store, siteID: "site-1")

        #expect(saved == false)
        #expect(!FileManager.default.fileExists(atPath: configDirectory.appendingPathComponent("conventions.json").path))
        #expect(await engine.conventions(siteID: "site-1") == nil)
    }

    @Test("non-empty answers on an unseeded engine seed from disk, apply overrides, and persist")
    func nonEmptyAnswersSeedApplyAndPersist() async {
        let engine = ProjectConventionsEngine()
        let configDirectory = makeConfigDirectory()
        let store = ProjectConventionsStore(configDirectory: configDirectory)

        // Pre-existing persisted state the engine hasn't seen yet (simulates a prior session).
        var existing = ProjectConventions.empty
        existing.apply(.brandTerms(["SourdoughLab"]))
        await store.save(existing)

        let answers = BrandVoiceAnswers(
            audience: "home bakers", toneWords: ["warm", "expert"], brandTerms: [], avoidPhrases: ["cheap"])

        let saved = await BrandVoiceWriter.save(answers, engine: engine, store: store, siteID: "site-1")

        #expect(saved == true)
        // Seeded from disk: the pre-existing brand term survives even though this call didn't
        // supply one.
        let engineConventions = await engine.conventions(siteID: "site-1")
        #expect(engineConventions?.writing.brandTerms.value == ["SourdoughLab"])
        #expect(engineConventions?.writing.audience.value == "home bakers")
        #expect(engineConventions?.writing.audience.isOverridden == true)
        #expect(engineConventions?.writing.toneDescriptors.value == ["warm", "expert"])
        #expect(engineConventions?.writing.avoidPhrases.value == ["cheap"])

        let persisted = await store.load()
        #expect(persisted?.writing.audience.value == "home bakers")
        #expect(persisted?.writing.audience.isOverridden == true)
        #expect(persisted?.writing.brandTerms.value == ["SourdoughLab"])
    }

    /// The data-loss regression the reviewer flagged: a chat-driven save through
    /// `BrandVoiceWriter` must survive a later, unrelated GUI override that persists the shared
    /// engine's full snapshot (mirroring `ProjectConventionsModel.setOverride`). Before this fix,
    /// `SaveBrandVoiceTool` wrote to a second store instance the engine never observed, so this
    /// second save would silently revert the chat answer.
    @Test("a chat-driven save survives a later unrelated engine-snapshot persist")
    func chatSaveSurvivesLaterEngineSnapshotPersist() async {
        let engine = ProjectConventionsEngine()
        let configDirectory = makeConfigDirectory()
        let store = ProjectConventionsStore(configDirectory: configDirectory)

        let chatAnswers = BrandVoiceAnswers(
            audience: "home bakers", toneWords: [], brandTerms: [], avoidPhrases: [])
        let saved = await BrandVoiceWriter.save(chatAnswers, engine: engine, store: store, siteID: "site-1")
        #expect(saved == true)

        // Mimic `ProjectConventionsModel.setOverride`: apply an unrelated override directly on
        // the same shared engine, then persist the engine's full in-memory snapshot.
        await engine.applyOverride(siteID: "site-1", value: .brandTerms(["SourdoughLab"]))
        if let merged = await engine.conventions(siteID: "site-1") {
            await store.save(merged)
        }

        let persisted = await store.load()
        #expect(persisted?.writing.audience.value == "home bakers")
        #expect(persisted?.writing.audience.isOverridden == true)
        #expect(persisted?.writing.brandTerms.value == ["SourdoughLab"])
    }
}
