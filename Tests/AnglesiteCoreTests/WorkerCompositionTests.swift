// Tests/AnglesiteCoreTests/WorkerCompositionTests.swift
import Testing
@testable import AnglesiteCore

@Suite("WorkerComposition")
struct WorkerCompositionTests {
    @Test("generates wrangler.toml with static assets and no social features")
    func staticOnly() {
        let toml = WorkerComposition.generateWranglerToml(
            siteName: "my-site",
            features: []
        )
        #expect(toml.contains("name = \"my-site\""))
        #expect(toml.contains("[assets]"))
        #expect(toml.contains("directory = \"dist\""))
        #expect(!toml.contains("[[d1_databases]]"))
    }

    @Test("generates wrangler.toml with webmention + indieauth (D1 yes, R2 no)")
    func withSocialFeatures() {
        let toml = WorkerComposition.generateWranglerToml(
            siteName: "my-site",
            features: [.webmention, .indieauth]
        )
        #expect(toml.contains("name = \"my-site\""))
        #expect(toml.contains("[assets]"))
        #expect(toml.contains("[[d1_databases]]"))
        #expect(toml.contains("binding = \"DB\""))
        #expect(!toml.contains("[[r2_buckets]]"))
    }

    @Test("generates wrangler.toml with V-2 features (D1 yes, R2 no — micropub is V-3)")
    func v2Features() {
        let toml = WorkerComposition.generateWranglerToml(
            siteName: "my-site",
            features: WorkerComposition.Feature.v2
        )
        #expect(toml.contains("[[d1_databases]]"))
        #expect(!toml.contains("[[r2_buckets]]"))
    }

    @Test("generates wrangler.toml with V-3 features (D1 + R2 — micropub needs media)")
    func v3Features() {
        let toml = WorkerComposition.generateWranglerToml(
            siteName: "my-site",
            features: WorkerComposition.Feature.v3
        )
        #expect(toml.contains("[[d1_databases]]"))
        #expect(toml.contains("[[r2_buckets]]"))
        #expect(toml.contains("binding = \"MEDIA\""))
    }

    @Test("feature sets are correctly defined per phase")
    func featureSets() {
        #expect(WorkerComposition.Feature.v2.contains(.webmention))
        #expect(WorkerComposition.Feature.v2.contains(.indieauth))
        #expect(!WorkerComposition.Feature.v2.contains(.micropub))

        #expect(WorkerComposition.Feature.v3.contains(.micropub))
        #expect(WorkerComposition.Feature.v3.contains(.websub))
    }
}
