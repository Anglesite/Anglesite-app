import Foundation
import Testing
@testable import AnglesiteCore

@Suite("SocialWorkerProvisionCommand")
struct SocialWorkerProvisionCommandTests {
    @Test("provisions V-2 D1 and KV, writes wrangler.toml, then deploys")
    func provisionsV2Worker() async throws {
        let site = try temporaryDirectory()
        let recorder = WranglerRecorder([
            ["d1", "create", "my-site-social", "--json"]: .init(stdout: #"{"result":{"uuid":"d1-id"}}"#, stderr: "", exitCode: 0),
            ["kv", "namespace", "create", "my-site-social", "--json"]: .init(stdout: #"{"result":{"id":"kv-id"}}"#, stderr: "", exitCode: 0),
            ["deploy"]: .init(stdout: "Published my-site (1.23 sec)\n  https://my-site.example.workers.dev", stderr: "", exitCode: 0),
        ])
        let command = SocialWorkerProvisionCommand(tokenSource: { "token" }, runner: recorder.runner)

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
            ["deploy"],
        ])
        #expect(await recorder.environments.allSatisfy { $0["CLOUDFLARE_API_TOKEN"] == "token" })

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
            ["deploy"]: .init(stdout: "Published my-site\nhttps://my-site.example.workers.dev", stderr: "", exitCode: 0),
        ])
        let command = SocialWorkerProvisionCommand(tokenSource: { "token" }, runner: recorder.runner)

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

        guard case .failed(let reason, nil) = result else {
            Issue.record("expected token failure, got \(result)")
            return
        }
        #expect(reason.contains("no CLOUDFLARE_API_TOKEN"))
        #expect(await recorder.arguments.isEmpty)
    }

    @Test("extracts resource ids from common wrangler JSON shapes")
    func resourceIDExtraction() {
        #expect(SocialWorkerProvisionCommand.extractResourceID(from: #"{"result":{"uuid":"d1-id"}}"#) == "d1-id")
        #expect(SocialWorkerProvisionCommand.extractResourceID(from: #"{"id":"kv-id"}"#) == "kv-id")
        #expect(SocialWorkerProvisionCommand.extractResourceID(from: #"{"result":[{"database_id":"db-id"}]}"#) == "db-id")
        #expect(SocialWorkerProvisionCommand.extractResourceID(from: #"binding = "SOCIAL_KV"\nid = "text-id""#) == "text-id")
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("SocialWorkerProvisionCommandTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
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
