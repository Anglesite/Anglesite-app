// Tests/AnglesiteCoreTests/WorkerCompositionTests.swift
import Testing
import Foundation
@testable import AnglesiteCore

private func worker(_ id: String, d1: Bool, kv: Bool, r2: Bool) -> WorkerDescriptor {
    WorkerDescriptor(
        id: id, displayName: id, description: "test fixture", group: "test",
        binding: .settingsActivated, resources: .init(needsD1: d1, needsKV: kv, needsR2: r2)
    )
}

private let genericD1KVWorker = worker("generic-d1kv-fixture", d1: true, kv: true, r2: false)
private let indieauthWorker = worker("indieauth", d1: true, kv: true, r2: false)
private let micropubWorker = worker("micropub", d1: true, kv: true, r2: true)
private let websubWorker = worker("websub", d1: true, kv: true, r2: false)
private let v2Workers = [genericD1KVWorker, indieauthWorker]
private let v3Workers = [genericD1KVWorker, indieauthWorker, micropubWorker, websubWorker]

@Suite("WorkerComposition")
struct WorkerCompositionTests {
    @Test("generates wrangler.toml with static assets and no social features")
    func staticOnly() throws {
        let toml = try WorkerComposition.generateWranglerToml(
            siteName: "my-site",
            workers: []
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
            workers: [genericD1KVWorker, indieauthWorker]
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
        // No route claims → no run_worker_first at all (#746): unclaimed paths stay asset-first,
        // and the worker still receives its endpoints via Cloudflare's asset-miss fallback.
        #expect(!toml.contains("run_worker_first"))
        #expect(toml.contains("# Secrets required for IndieAuth (set with `wrangler secret put <NAME>`):"))
        #expect(toml.contains("# TOKEN_SIGNING_KEY, INDIEAUTH_OWNER_PASSWORD"))
        #expect(!toml.contains("[secrets]"))
        #expect(toml.contains("[observability]"))
        #expect(!toml.contains("[[r2_buckets]]"))
    }

    @Test("generates wrangler.toml with V-2 workers (D1 yes, R2 no — micropub is V-3)")
    func v2Features() throws {
        let toml = try WorkerComposition.generateWranglerToml(
            siteName: "my-site",
            workers: v2Workers
        )
        #expect(toml.contains("[[d1_databases]]"))
        #expect(toml.contains("[[kv_namespaces]]"))
        #expect(!toml.contains("[[r2_buckets]]"))
    }

    @Test("generates wrangler.toml with V-3 workers (D1 + R2 — micropub needs media)")
    func v3Features() throws {
        let toml = try WorkerComposition.generateWranglerToml(
            siteName: "my-site",
            workers: v3Workers
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
            workers: v3Workers,
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
                workers: []
            )
        }
    }

    @Test("inboxCaptureEnabled adds an INBOX_KV binding and uncomments main even with no @dwk/* workers")
    func inboxCaptureAddsKVBinding() throws {
        let toml = try WorkerComposition.generateWranglerToml(
            siteName: "my-site", workers: [], inboxCaptureEnabled: true)
        #expect(toml.contains("main = \"worker/worker.ts\""))
        #expect(toml.contains("binding = \"INBOX_KV\""))
        #expect(toml.contains("id = \"\"  # filled by provisioning"))
    }

    @Test("inboxCaptureEnabled fills the provisioned namespace id when given")
    func inboxCaptureFillsProvisionedID() throws {
        let toml = try WorkerComposition.generateWranglerToml(
            siteName: "my-site", workers: [], inboxCaptureEnabled: true, inboxKVNamespaceID: "abc123")
        #expect(toml.contains("id = \"abc123\""))
    }

    @Test("inboxCaptureEnabled false omits the INBOX_KV binding")
    func inboxCaptureDisabledOmitsBinding() throws {
        let toml = try WorkerComposition.generateWranglerToml(siteName: "my-site", workers: [])
        #expect(!toml.contains("INBOX_KV"))
        #expect(!toml.contains("main ="))
    }

    @Test("route claims emit deterministic, sorted, deduplicated run_worker_first entries")
    func selectiveRunWorkerFirst() throws {
        let claims = [
            WorkerRouteClaim(path: "/token", match: .exact, methods: ["POST"], handler: "indieauth"),
            WorkerRouteClaim(path: "/authorize", match: .exact, methods: ["GET", "POST"], handler: "indieauth"),
            WorkerRouteClaim(path: "/authorize", match: .exact, methods: ["GET", "POST"], handler: "indieauth"),
            WorkerRouteClaim(
                path: "/.well-known/acme-challenge", match: .prefix, methods: ["GET"], handler: "acme",
                specificationURL: URL(string: "https://www.rfc-editor.org/rfc/rfc8555")),
        ]
        let toml = try WorkerComposition.generateWranglerToml(
            siteName: "my-site", workers: [indieauthWorker], routeClaims: claims)
        #expect(toml.contains(
            #"run_worker_first = ["/.well-known/acme-challenge", "/.well-known/acme-challenge/*", "/authorize", "/token"]"#
        ))
        // Regeneration is byte-stable regardless of claim order.
        let regenerated = try WorkerComposition.generateWranglerToml(
            siteName: "my-site", workers: [indieauthWorker], routeClaims: claims.reversed())
        #expect(toml == regenerated)
    }

    @Test("run_worker_first is omitted entirely when there are no active dynamic routes")
    func omitsRunWorkerFirstWithoutClaims() throws {
        let toml = try WorkerComposition.generateWranglerToml(
            siteName: "my-site", workers: [genericD1KVWorker, indieauthWorker])
        #expect(!toml.contains("run_worker_first"))
        #expect(toml.contains("binding = \"ASSETS\""))
    }

    @Test("inbox capture claims /inbox as a worker-first route")
    func inboxCaptureClaimsRoute() throws {
        let toml = try WorkerComposition.generateWranglerToml(
            siteName: "my-site", workers: [], inboxCaptureEnabled: true)
        #expect(toml.contains(#"run_worker_first = ["/inbox"]"#))
    }

    @Test("static-only sites emit no run_worker_first")
    func staticOnlyOmitsRunWorkerFirst() throws {
        let toml = try WorkerComposition.generateWranglerToml(siteName: "my-site", workers: [])
        #expect(!toml.contains("run_worker_first"))
    }

    @Test("an unvalidated route claim path is refused, not interpolated into TOML")
    func rejectsInvalidRouteClaim() {
        let hostile = WorkerRouteClaim(
            path: "/a\"]\ninjected = true", match: .exact, methods: ["GET"], handler: "x")
        #expect(throws: WorkerComposition.ConfigError.self) {
            try WorkerComposition.generateWranglerToml(
                siteName: "my-site", workers: [indieauthWorker], routeClaims: [hostile])
        }
    }

    @Test("composition runs full claim validation, not just path syntax")
    func rejectsSemanticallyInvalidRouteClaim() {
        // Valid path, invalid methods (HEAD without paired GET) — only full validation catches it.
        let headOnly = WorkerRouteClaim(
            path: "/status", match: .exact, methods: ["HEAD"], handler: "x")
        #expect(throws: WorkerComposition.ConfigError.self) {
            try WorkerComposition.generateWranglerToml(
                siteName: "my-site", workers: [indieauthWorker], routeClaims: [headOnly])
        }
    }

    @Test("ProvisionedResources round-trips through JSONEncoder/JSONDecoder")
    func provisionedResourcesCodable() throws {
        let resources = WorkerComposition.ProvisionedResources(
            d1DatabaseID: "d1-id", kvNamespaceID: "kv-id", r2BucketName: "media-bucket"
        )
        let data = try JSONEncoder().encode(resources)
        let decoded = try JSONDecoder().decode(WorkerComposition.ProvisionedResources.self, from: data)
        #expect(decoded == resources)
    }
}
