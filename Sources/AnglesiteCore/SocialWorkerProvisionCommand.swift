import Foundation

/// Provisions and deploys the per-site Cloudflare Worker used by the V-2 social layer.
///
/// This is the app-side integration seam for `@dwk/workers`: it creates the backing Cloudflare
/// resources with wrangler, writes a concrete `wrangler.toml`, then deploys the composed Worker.
/// The Worker source itself stays in the template's `worker/worker.ts`; when the upstream
/// `@dwk/*` packages are stable, that file is the only protocol-specific piece that needs to
/// grow imports and route handlers.
public actor SocialWorkerProvisionCommand {
    public enum Result: Sendable, Equatable {
        case succeeded(url: URL, resources: WorkerComposition.ProvisionedResources, duration: TimeInterval)
        case failed(reason: String, exitCode: Int32?)
    }

    public typealias TokenSource = DeployCommand.TokenSource
    public typealias CommandRunner = @Sendable (
        _ siteDirectory: URL,
        _ arguments: [String],
        _ environment: [String: String],
        _ source: String
    ) async throws -> ProcessSupervisor.RunResult

    public nonisolated let tokenSource: TokenSource
    private let runner: CommandRunner

    public init(
        tokenSource: @escaping TokenSource = DeployCommand.keychainTokenSource,
        runner: @escaping CommandRunner = SocialWorkerProvisionCommand.defaultRunner
    ) {
        self.tokenSource = tokenSource
        self.runner = runner
    }

    public func provision(
        siteID: String,
        siteDirectory: URL,
        siteName: String,
        features: [WorkerComposition.Feature] = WorkerComposition.Feature.v2
    ) async -> Result {
        let token: String?
        do {
            token = try await tokenSource()
        } catch {
            return .failed(reason: "couldn't read Cloudflare API token: \(error)", exitCode: nil)
        }
        guard let token, !token.isEmpty else {
            return .failed(reason: "no CLOUDFLARE_API_TOKEN — add it in Settings → Advanced → Credentials, or set the env var", exitCode: nil)
        }

        do {
            _ = try WorkerComposition.generateWranglerToml(siteName: siteName, features: features)
        } catch {
            return .failed(reason: "invalid Worker name: \(siteName)", exitCode: nil)
        }

        var environment = DeployCommand.hostDeployEnvironment()
        environment["CLOUDFLARE_API_TOKEN"] = token
        let source = "worker-provision:\(siteID)"
        let started = Date()

        var resources = WorkerComposition.ProvisionedResources()

        if features.contains(where: { $0.needsD1 }) {
            let name = "\(siteName)-social"
            let result = await runWrangler(
                siteDirectory: siteDirectory,
                arguments: ["d1", "create", name, "--json"],
                environment: environment,
                source: source
            )
            guard case .success(let output) = result else { return result.failure! }
            guard let id = Self.extractResourceID(from: output) else {
                return .failed(reason: "wrangler created D1 database \(name) but no database id was found", exitCode: 0)
            }
            resources.d1DatabaseID = id
        }

        if features.contains(where: { $0.needsKV }) {
            let name = "\(siteName)-social"
            let result = await runWrangler(
                siteDirectory: siteDirectory,
                arguments: ["kv", "namespace", "create", name, "--json"],
                environment: environment,
                source: source
            )
            guard case .success(let output) = result else { return result.failure! }
            guard let id = Self.extractResourceID(from: output) else {
                return .failed(reason: "wrangler created KV namespace \(name) but no namespace id was found", exitCode: 0)
            }
            resources.kvNamespaceID = id
        }

        if features.contains(where: { $0.needsR2 }) {
            let name = "\(siteName)-media"
            let result = await runWrangler(
                siteDirectory: siteDirectory,
                arguments: ["r2", "bucket", "create", name],
                environment: environment,
                source: source
            )
            guard case .success = result else { return result.failure! }
            resources.r2BucketName = name
        }

        do {
            let toml = try WorkerComposition.generateWranglerToml(
                siteName: siteName,
                features: features,
                resources: resources
            )
            try toml.write(
                to: siteDirectory.appendingPathComponent("wrangler.toml"),
                atomically: true,
                encoding: .utf8
            )
        } catch {
            return .failed(reason: "couldn't write wrangler.toml: \(error)", exitCode: nil)
        }

        let deploy = await runWrangler(
            siteDirectory: siteDirectory,
            arguments: ["deploy"],
            environment: environment,
            source: source
        )
        guard case .success(let output) = deploy else { return deploy.failure! }
        guard let url = DeployCommand.extractDeployedURL(from: output) else {
            return .failed(reason: "wrangler exited cleanly but no deployed URL was found in its output", exitCode: 0)
        }

        return .succeeded(url: url, resources: resources, duration: Date().timeIntervalSince(started))
    }

    private enum StepResult {
        case success(String)
        case failure(Result)

        var failure: Result? {
            if case .failure(let result) = self { result } else { nil }
        }
    }

    private func runWrangler(
        siteDirectory: URL,
        arguments: [String],
        environment: [String: String],
        source: String
    ) async -> StepResult {
        do {
            let result = try await runner(siteDirectory, arguments, environment, source)
            let output = result.stdout.isEmpty ? result.stderr : result.stdout
            guard result.exitCode == 0 else {
                return .failure(.failed(reason: output.isEmpty ? "wrangler exited with code \(result.exitCode)" : output, exitCode: result.exitCode))
            }
            return .success(output)
        } catch {
            return .failure(.failed(reason: "wrangler could not run: \(error)", exitCode: nil))
        }
    }

    public static func extractResourceID(from output: String) -> String? {
        if let data = output.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data),
           let id = findID(in: json) {
            return id
        }
        let pattern = #""?(?:id|uuid|database_id|namespace_id)"?\s*[:=]\s*"([^"]+)""#
        if let regex = try? NSRegularExpression(pattern: pattern),
           let match = regex.firstMatch(in: output, range: NSRange(output.startIndex..., in: output)),
           match.numberOfRanges > 1,
           let range = Range(match.range(at: 1), in: output) {
            return String(output[range])
        }
        return nil
    }

    private static func findID(in value: Any) -> String? {
        if let dict = value as? [String: Any] {
            for key in ["id", "uuid", "database_id", "namespace_id"] {
                if let id = dict[key] as? String, !id.isEmpty {
                    return id
                }
            }
            for child in dict.values {
                if let id = findID(in: child) {
                    return id
                }
            }
        }
        if let array = value as? [Any] {
            for child in array {
                if let id = findID(in: child) {
                    return id
                }
            }
        }
        return nil
    }

    public static let defaultRunner: CommandRunner = { siteDirectory, arguments, environment, source in
        let wranglerBin = siteDirectory
            .appendingPathComponent("node_modules", isDirectory: true)
            .appendingPathComponent(".bin", isDirectory: true)
            .appendingPathComponent("wrangler")
        guard FileManager.default.isExecutableFile(atPath: wranglerBin.path) else {
            return ProcessSupervisor.RunResult(
                stdout: "wrangler not installed — run `npm install` in this site",
                stderr: "",
                exitCode: 127
            )
        }
        guard let node = NodeRuntime.bundledExecutableURL else {
            return ProcessSupervisor.RunResult(
                stdout: "the embedded Node runtime isn't bundled (rebuild the app)",
                stderr: "",
                exitCode: 127
            )
        }

        let result = try await ProcessSupervisor.shared.run(
            executable: node,
            arguments: [wranglerBin.path] + arguments,
            environment: environment,
            currentDirectoryURL: siteDirectory
        )
        await append(result.stdout, source: source, stream: .stdout)
        await append(result.stderr, source: source, stream: .stderr)
        return result
    }

    private static func append(_ text: String, source: String, stream: LogCenter.Stream) async {
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) where !line.isEmpty {
            await LogCenter.shared.append(source: source, stream: stream, text: String(line))
        }
    }
}
