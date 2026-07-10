// Tests/AnglesiteCoreTests/BrandVoiceGuidanceTests.swift
import Testing
import Foundation
@testable import AnglesiteCore

@Suite struct BrandVoiceGuidanceTests {
    @Test func emptyConventionsYieldNil() {
        #expect(BrandVoiceGuidance.preamble(conventions: .empty, businessType: nil) == nil)
        #expect(BrandVoiceGuidance.preamble(conventions: nil, businessType: nil) == nil)
    }

    @Test func businessTypeAloneYieldsPreamble() {
        let p = BrandVoiceGuidance.preamble(conventions: nil, businessType: "bakery")
        #expect(p?.contains("bakery") == true)
    }

    @Test func learnedFieldsAppearInPreamble() {
        var c = ProjectConventions.empty
        c.writing.toneDescriptors = Learned(value: ["warm", "expert"], source: .inferred(confidence: 0.8), sampleSize: 12)
        c.writing.brandTerms = Learned(value: ["SourdoughLab"], source: .inferred(confidence: 0.9), sampleSize: 12)
        c.apply(.audience("home bakers"))
        c.apply(.avoidPhrases(["artisanal"]))
        let p = BrandVoiceGuidance.preamble(conventions: c, businessType: nil)
        #expect(p?.contains("warm, expert") == true)
        #expect(p?.contains("SourdoughLab") == true)
        #expect(p?.contains("home bakers") == true)
        #expect(p?.contains("artisanal") == true)
    }

    /// Zero-sample inferred values are noise, not signal — they must not leak into prompts.
    @Test func zeroSampleUnoverriddenFieldsAreSkipped() {
        var c = ProjectConventions.empty
        c.writing.toneDescriptors = Learned(value: ["stale"], source: .inferred(confidence: 0), sampleSize: 0)
        #expect(BrandVoiceGuidance.preamble(conventions: c, businessType: nil) == nil)
    }

    @Test func readsBusinessTypeFromSiteConfig() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("bvg-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try "BUSINESS_TYPE=bakery\nSITE_NAME=SourdoughLab\n"
            .write(to: dir.appendingPathComponent(".site-config"), atomically: true, encoding: .utf8)
        #expect(SiteBusinessType.read(sourceDirectory: dir) == "bakery")
        #expect(SiteBusinessType.read(sourceDirectory: dir.appendingPathComponent("missing")) == nil)
    }
}
