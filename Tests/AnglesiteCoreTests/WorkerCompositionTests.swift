// Tests/AnglesiteCoreTests/WorkerCompositionTests.swift
import Testing
@testable import AnglesiteCore

@Suite("WorkerComposition")
struct WorkerCompositionTests {
    @Test("generates wrangler.toml with static assets and no social features")
    func staticOnly() throws {
        let toml = try WorkerComposition.generateWranglerToml(
            siteName: "my-site",
            features: []
        )
        #expect(toml.contains("name = \"my-site\""))
        #expect(toml.contains("[assets]"))
        #expect(toml.contains("directory = \"dist\""))
        #expect(!toml.contains("[[d1_databases]]"))
    }

    @Test("generates wrangler.toml with webmention + indieauth (D1 + KV yes, R2 no)")
    func withSocialFeatures() throws {
        let toml = try WorkerComposition.generateWranglerToml(
            siteName: "my-site",
            features: [.webmention, .indieauth]
        )
        #expect(toml.contains("name = \"my-site\""))
        #expect(toml.contains("[assets]"))
        #expect(toml.contains("[[d1_databases]]"))
        #expect(toml.contains("binding = \"DB\""))
        #expect(toml.contains("binding = \"AUTH_DB\""))
        #expect(toml.contains("migrations_dir = \"worker/migrations\""))
        #expect(toml.contains("[[kv_namespaces]]"))
        #expect(toml.contains("binding = \"SOCIAL_KV\""))
        #expect(toml.contains("binding = \"ASSETS\""))
        #expect(toml.contains("run_worker_first = true"))
        #expect(toml.contains("required = [\"TOKEN_SIGNING_KEY\", \"INDIEAUTH_OWNER_PASSWORD\"]"))
        #expect(toml.contains("[observability]"))
        #expect(!toml.contains("[[r2_buckets]]"))
    }

    @Test("generates wrangler.toml with V-2 features (D1 yes, R2 no — micropub is V-3)")
    func v2Features() throws {
        let toml = try WorkerComposition.generateWranglerToml(
            siteName: "my-site",
            features: WorkerComposition.Feature.v2
        )
        #expect(toml.contains("[[d1_databases]]"))
        #expect(toml.contains("[[kv_namespaces]]"))
        #expect(!toml.contains("[[r2_buckets]]"))
    }

    @Test("generates wrangler.toml with V-3 features (D1 + R2 — micropub needs media)")
    func v3Features() throws {
        let toml = try WorkerComposition.generateWranglerToml(
            siteName: "my-site",
            features: WorkerComposition.Feature.v3
        )
        #expect(toml.contains("[[d1_databases]]"))
        #expect(toml.contains("[[kv_namespaces]]"))
        #expect(toml.contains("[[r2_buckets]]"))
        #expect(toml.contains("binding = \"MEDIA\""))
    }

    @Test("writes provisioned Cloudflare resource ids into wrangler.toml")
    func provisionedResources() throws {
        let toml = try WorkerComposition.generateWranglerToml(
            siteName: "my-site",
            features: WorkerComposition.Feature.v3,
            resources: .init(d1DatabaseID: "d1-id", kvNamespaceID: "kv-id", r2BucketName: "custom-media")
        )

        #expect(toml.contains("database_id = \"d1-id\""))
        #expect(toml.contains("id = \"kv-id\""))
        #expect(toml.contains("bucket_name = \"custom-media\""))
    }

    @Test("rejects site names containing TOML-unsafe characters")
    func rejectsInvalidSiteName() {
        #expect(throws: WorkerComposition.ConfigError.self) {
            try WorkerComposition.generateWranglerToml(
                siteName: "my\"site\ninjected",
                features: []
            )
        }
    }

    @Test("feature sets are correctly defined per phase")
    func featureSets() {
        #expect(WorkerComposition.Feature.v2.contains(.webmention))
        #expect(WorkerComposition.Feature.v2.contains(.indieauth))
        #expect(!WorkerComposition.Feature.v2.contains(.micropub))

        #expect(WorkerComposition.Feature.v3.contains(.micropub))
        #expect(WorkerComposition.Feature.v3.contains(.websub))
    }

    @Test("inboxCaptureEnabled adds an INBOX_KV binding and uncomments main even with no @dwk/* features")
    func inboxCaptureAddsKVBinding() throws {
        let toml = try WorkerComposition.generateWranglerToml(
            siteName: "my-site", features: [], inboxCaptureEnabled: true)
        #expect(toml.contains("main = \"worker/worker.ts\""))
        #expect(toml.contains("binding = \"INBOX_KV\""))
        #expect(toml.contains("id = \"\"  # filled by provisioning"))
    }

    @Test("inboxCaptureEnabled fills the provisioned namespace id when given")
    func inboxCaptureFillsProvisionedID() throws {
        let toml = try WorkerComposition.generateWranglerToml(
            siteName: "my-site", features: [], inboxCaptureEnabled: true, inboxKVNamespaceID: "abc123")
        #expect(toml.contains("id = \"abc123\""))
    }

    @Test("inboxCaptureEnabled false omits the INBOX_KV binding")
    func inboxCaptureDisabledOmitsBinding() throws {
        let toml = try WorkerComposition.generateWranglerToml(siteName: "my-site", features: [])
        #expect(!toml.contains("INBOX_KV"))
        #expect(!toml.contains("main ="))
    }
}
