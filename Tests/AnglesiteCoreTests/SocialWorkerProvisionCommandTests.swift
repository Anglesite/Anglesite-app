import Foundation
import Testing
@testable import AnglesiteCore

@Suite("SocialWorkerProvisionCommand")
struct SocialWorkerProvisionCommandTests {
    @Test("provisions V-2 D1 and KV, writes wrangler.toml, then deploys through DeployCommand seam")
    func provisionsV2Worker() async throws {
        let site = try temporaryDirectory()
        let recorder = WranglerRecorder([
            ["d1", "create", "my-site-social", "--json"]: .init(stdout: #"{"result":{"uuid":"d1-id"}}"#, stderr: "", exitCode: 0),
            ["kv", "namespace", "create", "my-site-social", "--json"]: .init(stdout: #"{"result":{"id":"kv-id"}}"#, stderr: "", exitCode: 0),
            ["d1", "migrations", "apply", "AUTH_DB", "--remote"]: .init(stdout: "Migrations applied", stderr: "", exitCode: 0),
        ])
        let deployer = DeployRecorder(result: .succeeded(url: URL(string: "https://my-site.example.workers.dev")!, duration: 1))
        let command = SocialWorkerProvisionCommand(tokenSource: { "token" }, runner: recorder.runner, deployer: deployer.deployer)

        let result = await command.provision(siteID: "site-1", siteDirectory: site, siteName: "my-site")

        guard case .succeeded(let url, let resources, _) = result else {
            Issue.record("expected success, got \(result)")
            return
        }
        #expect(url == URL(string: "https://my-site.example.workers.dev"))
        #expect(resources.d1DatabaseID == "d1-id")
        #expect(resources.kvNamespaceID == "kv-id")
        #expect(resources.r2BucketName == nil)
        #expect(await recorder.arguments == [
            ["d1", "create", "my-site-social", "--json"],
            ["kv", "namespace", "create", "my-site-social", "--json"],
            ["d1", "migrations", "apply", "AUTH_DB", "--remote"],
        ])
        #expect(await recorder.environments.allSatisfy { $0["CLOUDFLARE_API_TOKEN"] == "token" })
        #expect(await deployer.calls == [.init(token: "token", siteID: "site-1", siteDirectory: site)])

        let toml = try String(contentsOf: site.appendingPathComponent("wrangler.toml"), encoding: .utf8)
        #expect(toml.contains("main = \"worker/worker.ts\""))
        #expect(toml.contains("database_id = \"d1-id\""))
        #expect(toml.contains("id = \"kv-id\""))
        #expect(!toml.contains("[[r2_buckets]]"))
    }

    @Test("provisions R2 only when a selected feature needs media")
    func provisionsR2ForMicropub() async throws {
        let site = try temporaryDirectory()
        let recorder = WranglerRecorder([
            ["d1", "create", "my-site-social", "--json"]: .init(stdout: #"{"uuid":"d1-id"}"#, stderr: "", exitCode: 0),
            ["kv", "namespace", "create", "my-site-social", "--json"]: .init(stdout: #"{"id":"kv-id"}"#, stderr: "", exitCode: 0),
            ["r2", "bucket", "create", "my-site-media"]: .init(stdout: "Created bucket my-site-media", stderr: "", exitCode: 0),
            ["d1", "migrations", "apply", "AUTH_DB", "--remote"]: .init(stdout: "Migrations applied", stderr: "", exitCode: 0),
        ])
        let command = SocialWorkerProvisionCommand(
            tokenSource: { "token" },
            runner: recorder.runner,
            deployer: DeployRecorder(result: .succeeded(url: URL(string: "https://my-site.example.workers.dev")!, duration: 1)).deployer
        )

        let result = await command.provision(
            siteID: "site-1",
            siteDirectory: site,
            siteName: "my-site",
            features: WorkerComposition.Feature.v3
        )

        guard case .succeeded(_, let resources, _) = result else {
            Issue.record("expected success, got \(result)")
            return
        }
        #expect(resources.r2BucketName == "my-site-media")

        let toml = try String(contentsOf: site.appendingPathComponent("wrangler.toml"), encoding: .utf8)
        #expect(toml.contains("[[r2_buckets]]"))
        #expect(toml.contains("bucket_name = \"my-site-media\""))
    }

    @Test("fails before running wrangler when no token is available")
    func missingToken() async throws {
        let site = try temporaryDirectory()
        let recorder = WranglerRecorder([:])
        let command = SocialWorkerProvisionCommand(tokenSource: { nil }, runner: recorder.runner)

        let result = await command.provision(siteID: "site-1", siteDirectory: site, siteName: "my-site")

        guard case .failed(let reason, nil, let resources) = result else {
            Issue.record("expected token failure, got \(result)")
            return
        }
        #expect(reason.contains("no CLOUDFLARE_API_TOKEN"))
        #expect(resources == .init())
        #expect(await recorder.arguments.isEmpty)
    }

    @Test("reuses persisted resource ids and does not recreate Cloudflare backing stores")
    func reusesPersistedResources() async throws {
        let site = try temporaryDirectory()
        let existing = try WorkerComposition.generateWranglerToml(
            siteName: "my-site",
            features: WorkerComposition.Feature.v3,
            resources: .init(d1DatabaseID: "d1-existing", kvNamespaceID: "kv-existing", r2BucketName: "media-existing")
        )
        try existing.write(to: site.appendingPathComponent("wrangler.toml"), atomically: true, encoding: .utf8)

        let recorder = WranglerRecorder([
            ["d1", "migrations", "apply", "AUTH_DB", "--remote"]: .init(stdout: "Migrations applied", stderr: "", exitCode: 0),
        ])
        let command = SocialWorkerProvisionCommand(
            tokenSource: { "token" },
            runner: recorder.runner,
            deployer: DeployRecorder(result: .succeeded(url: URL(string: "https://my-site.example.workers.dev")!, duration: 1)).deployer
        )

        let result = await command.provision(
            siteID: "site-1",
            siteDirectory: site,
            siteName: "my-site",
            features: WorkerComposition.Feature.v3
        )

        guard case .succeeded(_, let resources, _) = result else {
            Issue.record("expected success, got \(result)")
            return
        }
        #expect(resources.d1DatabaseID == "d1-existing")
        #expect(resources.kvNamespaceID == "kv-existing")
        #expect(resources.r2BucketName == "media-existing")
        #expect(await recorder.arguments == [
            ["d1", "migrations", "apply", "AUTH_DB", "--remote"],
        ])
    }

    @Test("persists partial D1 resources and reports them when KV creation fails")
    func partialFailureReportsResources() async throws {
        let site = try temporaryDirectory()
        let recorder = WranglerRecorder([
            ["d1", "create", "my-site-social", "--json"]: .init(stdout: #"{"uuid":"d1-id"}"#, stderr: "", exitCode: 0),
            ["kv", "namespace", "create", "my-site-social", "--json"]: .init(stdout: "KV failed", stderr: "", exitCode: 1),
        ])
        let deployer = DeployRecorder(result: .succeeded(url: URL(string: "https://my-site.example.workers.dev")!, duration: 1))
        let command = SocialWorkerProvisionCommand(tokenSource: { "token" }, runner: recorder.runner, deployer: deployer.deployer)

        let result = await command.provision(siteID: "site-1", siteDirectory: site, siteName: "my-site")

        guard case .failed(let reason, let exitCode, let resources) = result else {
            Issue.record("expected failure, got \(result)")
            return
        }
        #expect(reason == "KV failed")
        #expect(exitCode == 1)
        #expect(resources.d1DatabaseID == "d1-id")
        #expect(resources.kvNamespaceID == nil)
        #expect(await deployer.calls.isEmpty)

        let toml = try String(contentsOf: site.appendingPathComponent("wrangler.toml"), encoding: .utf8)
        #expect(toml.contains("database_id = \"d1-id\""))
    }

    @Test("keeps provisioned resources when DeployCommand fails after config is written")
    func deployFailureReportsResources() async throws {
        let site = try temporaryDirectory()
        let recorder = WranglerRecorder([
            ["d1", "create", "my-site-social", "--json"]: .init(stdout: #"{"uuid":"d1-id"}"#, stderr: "", exitCode: 0),
            ["kv", "namespace", "create", "my-site-social", "--json"]: .init(stdout: #"{"id":"kv-id"}"#, stderr: "", exitCode: 0),
            ["d1", "migrations", "apply", "AUTH_DB", "--remote"]: .init(stdout: "Migrations applied", stderr: "", exitCode: 0),
        ])
        let command = SocialWorkerProvisionCommand(
            tokenSource: { "token" },
            runner: recorder.runner,
            deployer: DeployRecorder(result: .failed(reason: "pre-deploy scan could not run", exitCode: nil)).deployer
        )

        let result = await command.provision(siteID: "site-1", siteDirectory: site, siteName: "my-site")

        guard case .failed(let reason, nil, let resources) = result else {
            Issue.record("expected deploy failure, got \(result)")
            return
        }
        #expect(reason == "pre-deploy scan could not run")
        #expect(resources.d1DatabaseID == "d1-id")
        #expect(resources.kvNamespaceID == "kv-id")

        let toml = try String(contentsOf: site.appendingPathComponent("wrangler.toml"), encoding: .utf8)
        #expect(toml.contains("database_id = \"d1-id\""))
        #expect(toml.contains("id = \"kv-id\""))
    }

    @Test("a worker-name conflict from the deployer is propagated, not collapsed to failed")
    func workerNameConflictPropagates() async throws {
        let site = try temporaryDirectory()
        let recorder = WranglerRecorder([
            ["d1", "create", "my-site-social", "--json"]: .init(stdout: #"{"result":{"uuid":"d1-id"}}"#, stderr: "", exitCode: 0),
            ["kv", "namespace", "create", "my-site-social", "--json"]: .init(stdout: #"{"result":{"id":"kv-id"}}"#, stderr: "", exitCode: 0),
            ["d1", "migrations", "apply", "AUTH_DB", "--remote"]: .init(stdout: "Migrations applied", stderr: "", exitCode: 0),
        ])
        let deployer = DeployRecorder(result: .workerNameConflict(name: "taken-name"))
        let command = SocialWorkerProvisionCommand(tokenSource: { "token" }, runner: recorder.runner, deployer: deployer.deployer)

        let result = await command.provision(siteID: "site-1", siteDirectory: site, siteName: "my-site")

        guard case .workerNameConflict(let name, let resources) = result else {
            Issue.record("expected .workerNameConflict, got \(result)"); return
        }
        #expect(name == "taken-name")
        #expect(resources.d1DatabaseID == "d1-id")
        #expect(resources.kvNamespaceID == "kv-id")
    }

    @Test("stops before deploy when the IndieAuth schema migration fails")
    func migrationFailureStopsDeploy() async throws {
        let site = try temporaryDirectory()
        let recorder = WranglerRecorder([
            ["d1", "create", "my-site-social", "--json"]: .init(stdout: #"{"uuid":"d1-id"}"#, stderr: "", exitCode: 0),
            ["kv", "namespace", "create", "my-site-social", "--json"]: .init(stdout: #"{"id":"kv-id"}"#, stderr: "", exitCode: 0),
            ["d1", "migrations", "apply", "AUTH_DB", "--remote"]: .init(stdout: "Migration failed", stderr: "", exitCode: 1),
        ])
        let deployer = DeployRecorder(result: .succeeded(url: URL(string: "https://my-site.example.workers.dev")!, duration: 1))
        let command = SocialWorkerProvisionCommand(tokenSource: { "token" }, runner: recorder.runner, deployer: deployer.deployer)

        let result = await command.provision(siteID: "site-1", siteDirectory: site, siteName: "my-site")

        guard case .failed(let reason, let exitCode, let resources) = result else {
            Issue.record("expected migration failure, got \(result)")
            return
        }
        #expect(reason == "Migration failed")
        #expect(exitCode == 1)
        #expect(resources.d1DatabaseID == "d1-id")
        #expect(resources.kvNamespaceID == "kv-id")
        #expect(await deployer.calls.isEmpty)
    }

    @Test("extracts resource ids from common wrangler JSON shapes")
    func resourceIDExtraction() {
        #expect(SocialWorkerProvisionCommand.extractResourceID(from: #"{"result":{"uuid":"d1-id"}}"#) == "d1-id")
        #expect(SocialWorkerProvisionCommand.extractResourceID(from: #"{"id":"kv-id"}"#) == "kv-id")
        #expect(SocialWorkerProvisionCommand.extractResourceID(from: #"{"result":[{"database_id":"db-id"}]}"#) == "db-id")
        #expect(SocialWorkerProvisionCommand.extractResourceID(from: #"binding = "SOCIAL_KV"\nid = "text-id""#) == "text-id")
    }

    @Test("reads persisted resource ids from active wrangler.toml bindings only")
    func persistedResourceParsing() throws {
        let site = try temporaryDirectory()
        let toml = """
        # id = "commented-kv"
        name = "my-site"
        [[d1_databases]]
        database_id = "d1-id"
        [[kv_namespaces]]
        id = "kv-id"
        [[r2_buckets]]
        bucket_name = "media-bucket"
        """
        try toml.write(to: site.appendingPathComponent("wrangler.toml"), atomically: true, encoding: .utf8)

        let resources = SocialWorkerProvisionCommand.readPersistedResources(from: site)

        #expect(resources.d1DatabaseID == "d1-id")
        #expect(resources.kvNamespaceID == "kv-id")
        #expect(resources.r2BucketName == "media-bucket")
    }

    @Test("knownResources is reused instead of re-scraping wrangler.toml, so a deactivated-then-reactivated worker doesn't recreate its Cloudflare resource")
    func reusesKnownResourcesOverFileScrape() async throws {
        let site = try temporaryDirectory()
        // wrangler.toml on disk reflects the CURRENT (deactivated) feature set — no R2 block, so
        // a file-scrape alone would find no bucket name and try to recreate it.
        let currentToml = try WorkerComposition.generateWranglerToml(
            siteName: "my-site",
            features: [.indieauth],
            resources: .init(d1DatabaseID: "d1-id", kvNamespaceID: "kv-id", r2BucketName: nil)
        )
        try currentToml.write(to: site.appendingPathComponent("wrangler.toml"), atomically: true, encoding: .utf8)

        // knownResources (as persisted in SiteSettings before deactivation) still remembers the bucket.
        let known = WorkerComposition.ProvisionedResources(
            d1DatabaseID: "d1-id", kvNamespaceID: "kv-id", r2BucketName: "my-site-media"
        )
        let recorder = WranglerRecorder([
            ["d1", "migrations", "apply", "AUTH_DB", "--remote"]: .init(stdout: "Migrations applied", stderr: "", exitCode: 0),
        ])
        let command = SocialWorkerProvisionCommand(
            tokenSource: { "token" },
            runner: recorder.runner,
            deployer: DeployRecorder(result: .succeeded(url: URL(string: "https://my-site.example.workers.dev")!, duration: 1)).deployer
        )

        // Reactivating micropub (needs R2) should reuse the known bucket, not call `r2 bucket create` again.
        let result = await command.provision(
            siteID: "site-1", siteDirectory: site, siteName: "my-site",
            features: [.indieauth, .micropub], knownResources: known
        )

        guard case .succeeded(_, let resources, _) = result else {
            Issue.record("expected success, got \(result)")
            return
        }
        #expect(resources.r2BucketName == "my-site-media")
        #expect(await recorder.arguments == [
            ["d1", "migrations", "apply", "AUTH_DB", "--remote"],
        ])
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("SocialWorkerProvisionCommandTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

private struct DeployCall: Sendable, Equatable {
    let token: String
    let siteID: String
    let siteDirectory: URL
}

private actor DeployRecorder {
    private let result: DeployCommand.Result
    private var seenCalls: [DeployCall] = []

    init(result: DeployCommand.Result) {
        self.result = result
    }

    var calls: [DeployCall] { seenCalls }

    nonisolated var deployer: SocialWorkerProvisionCommand.Deployer {
        { token, siteID, siteDirectory in
            await self.deploy(token: token, siteID: siteID, siteDirectory: siteDirectory)
        }
    }

    private func deploy(token: String, siteID: String, siteDirectory: URL) -> DeployCommand.Result {
        seenCalls.append(DeployCall(token: token, siteID: siteID, siteDirectory: siteDirectory))
        return result
    }
}

private actor WranglerRecorder {
    private let responses: [[String]: ProcessSupervisor.RunResult]
    private var seenArguments: [[String]] = []
    private var seenEnvironments: [[String: String]] = []

    init(_ responses: [[String]: ProcessSupervisor.RunResult]) {
        self.responses = responses
    }

    var arguments: [[String]] { seenArguments }
    var environments: [[String: String]] { seenEnvironments }

    nonisolated var runner: SocialWorkerProvisionCommand.CommandRunner {
        { siteDirectory, arguments, environment, source in
            _ = siteDirectory
            _ = source
            return await self.run(arguments: arguments, environment: environment)
        }
    }

    private func run(arguments: [String], environment: [String: String]) -> ProcessSupervisor.RunResult {
        seenArguments.append(arguments)
        seenEnvironments.append(environment)
        return responses[arguments] ?? .init(stdout: "unexpected arguments \(arguments)", stderr: "", exitCode: 127)
    }
}
