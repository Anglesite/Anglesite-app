import Foundation

/// Provisions the per-site Cloudflare Worker resources used by the V-2 social layer, then
/// publishes through ``DeployCommand`` so build and pre-deploy security checks stay in path.
///
/// This is the app-side integration seam for `@dwk/workers`: it creates the backing Cloudflare
/// resources with wrangler, writes a concrete `wrangler.toml`, then asks the existing deploy
/// pipeline to build, scan, and deploy the composed Worker.
/// The Worker source itself stays in the template's `worker/worker.ts`; when the upstream
/// `@dwk/*` packages are stable, that file is the only protocol-specific piece that needs to
/// grow imports and route handlers.
public actor SocialWorkerProvisionCommand {
    public enum Result: Sendable, Equatable {
        case succeeded(url: URL, resources: WorkerComposition.ProvisionedResources, duration: TimeInterval)
        case blocked(failures: [PreDeployCheck.ScanFailure], warnings: [PreDeployCheck.ScanWarning], resources: WorkerComposition.ProvisionedResources)
        /// The candidate Worker name is already in use on the connected Cloudflare account and
        /// this site has never deployed before — mirrors `DeployCommand.Result.workerNameConflict`
        /// rather than collapsing it, so callers can drive the same rename-and-retry UX (#740).
        case workerNameConflict(name: String, resources: WorkerComposition.ProvisionedResources)
        case failed(reason: String, exitCode: Int32?, resources: WorkerComposition.ProvisionedResources)
    }

    public typealias TokenSource = DeployCommand.TokenSource
    public typealias CommandRunner = @Sendable (
        _ siteDirectory: URL,
        _ arguments: [String],
        _ environment: [String: String],
        _ source: String
    ) async throws -> ProcessSupervisor.RunResult
    public typealias Deployer = @Sendable (
        _ token: String,
        _ siteID: String,
        _ siteDirectory: URL
    ) async -> DeployCommand.Result

    public nonisolated let tokenSource: TokenSource
    private let runner: CommandRunner
    private let deployer: Deployer

    public init(
        tokenSource: @escaping TokenSource = DeployCommand.keychainTokenSource,
        runner: @escaping CommandRunner = SocialWorkerProvisionCommand.defaultRunner,
        deployer: @escaping Deployer = SocialWorkerProvisionCommand.defaultDeployer
    ) {
        self.tokenSource = tokenSource
        self.runner = runner
        self.deployer = deployer
    }

    public func provision(
        siteID: String,
        siteDirectory: URL,
        siteName: String,
        features: [WorkerComposition.Feature] = WorkerComposition.Feature.v2,
        /// Resources already known from `SiteSettings.provisionedWorkerResources` (#709), checked
        /// before falling back to `readPersistedResources`'s wrangler.toml scrape. Durable across
        /// a worker being deactivated (which drops its binding block from the file) and later
        /// reactivated — the default (`.init()`, all-nil) makes this call fall through to the
        /// existing file-scrape-only behavior unchanged.
        knownResources: WorkerComposition.ProvisionedResources = .init()
    ) async -> Result {
        let token: String?
        do {
            token = try await tokenSource()
        } catch {
            return .failed(reason: "couldn't read Cloudflare API token: \(error)", exitCode: nil, resources: .init())
        }
        guard let token, !token.isEmpty else {
            return .failed(
                reason: "no CLOUDFLARE_API_TOKEN — add it in Settings → Advanced → Credentials, or set the env var",
                exitCode: nil,
                resources: .init()
            )
        }

        guard WorkerComposition.isValidSiteName(siteName) else {
            return .failed(reason: "invalid Worker name: \(siteName)", exitCode: nil, resources: .init())
        }

        var environment = DeployCommand.hostDeployEnvironment()
        environment["CLOUDFLARE_API_TOKEN"] = token
        let source = "worker-provision:\(siteID)"
        let started = Date()

        var resources = knownResources == .init() ? Self.readPersistedResources(from: siteDirectory) : knownResources

        if features.contains(where: { $0.needsD1 }) {
            if resources.d1DatabaseID == nil {
                let name = "\(siteName)-social"
                let result = await runWrangler(
                    siteDirectory: siteDirectory,
                    arguments: ["d1", "create", name, "--json"],
                    environment: environment,
                    source: source,
                    resources: resources
                )
                let output: String
                switch result {
                case .success(let value):
                    output = value
                case .failure(let failure):
                    return failure
                }
                guard let id = Self.extractResourceID(from: output) else {
                    return .failed(reason: "wrangler created D1 database \(name) but no database id was found", exitCode: 0, resources: resources)
                }
                resources.d1DatabaseID = id
                if let failure = persistConfig(siteDirectory: siteDirectory, siteName: siteName, features: features, resources: resources) {
                    return failure
                }
            }
        }

        if features.contains(where: { $0.needsKV }) {
            if resources.kvNamespaceID == nil {
                let name = "\(siteName)-social"
                let result = await runWrangler(
                    siteDirectory: siteDirectory,
                    arguments: ["kv", "namespace", "create", name, "--json"],
                    environment: environment,
                    source: source,
                    resources: resources
                )
                let output: String
                switch result {
                case .success(let value):
                    output = value
                case .failure(let failure):
                    return failure
                }
                guard let id = Self.extractResourceID(from: output) else {
                    return .failed(reason: "wrangler created KV namespace \(name) but no namespace id was found", exitCode: 0, resources: resources)
                }
                resources.kvNamespaceID = id
                if let failure = persistConfig(siteDirectory: siteDirectory, siteName: siteName, features: features, resources: resources) {
                    return failure
                }
            }
        }

        if features.contains(where: { $0.needsR2 }) {
            if resources.r2BucketName == nil {
                let name = "\(siteName)-media"
                let result = await runWrangler(
                    siteDirectory: siteDirectory,
                    arguments: ["r2", "bucket", "create", name],
                    environment: environment,
                    source: source,
                    resources: resources
                )
                if case .failure(let failure) = result {
                    return failure
                }
                resources.r2BucketName = name
                if let failure = persistConfig(siteDirectory: siteDirectory, siteName: siteName, features: features, resources: resources) {
                    return failure
                }
            }
        }

        if let failure = persistConfig(siteDirectory: siteDirectory, siteName: siteName, features: features, resources: resources) {
            return failure
        }

        // @dwk/indieauth deliberately keeps schema deployment outside its request handler. Apply
        // the committed D1 migrations after wrangler.toml contains the concrete database id and
        // before publishing code that can receive authorization requests.
        if features.contains(.indieauth) {
            let result = await runWrangler(
                siteDirectory: siteDirectory,
                arguments: ["d1", "migrations", "apply", "AUTH_DB", "--remote"],
                environment: environment,
                source: source,
                resources: resources
            )
            if case .failure(let failure) = result {
                return failure
            }
        }

        switch await deployer(token, siteID, siteDirectory) {
        case .succeeded(let url, _):
            return .succeeded(url: url, resources: resources, duration: Date().timeIntervalSince(started))
        case .blocked(let failures, let warnings):
            return .blocked(failures: failures, warnings: warnings, resources: resources)
        case .workerNameConflict(let name):
            return .workerNameConflict(name: name, resources: resources)
        case .failed(let reason, let exitCode):
            return .failed(reason: reason, exitCode: exitCode, resources: resources)
        }
    }

    private enum StepResult {
        case success(String)
        case failure(Result)
    }

    private func runWrangler(
        siteDirectory: URL,
        arguments: [String],
        environment: [String: String],
        source: String,
        resources: WorkerComposition.ProvisionedResources
    ) async -> StepResult {
        do {
            let result = try await runner(siteDirectory, arguments, environment, source)
            let output = result.stdout.isEmpty ? result.stderr : result.stdout
            guard result.exitCode == 0 else {
                return .failure(.failed(
                    reason: output.isEmpty ? "wrangler exited with code \(result.exitCode)" : output,
                    exitCode: result.exitCode,
                    resources: resources
                ))
            }
            return .success(output)
        } catch {
            return .failure(.failed(reason: "wrangler could not run: \(error)", exitCode: nil, resources: resources))
        }
    }

    private func persistConfig(
        siteDirectory: URL,
        siteName: String,
        features: [WorkerComposition.Feature],
        resources: WorkerComposition.ProvisionedResources
    ) -> Result? {
        do {
            // Called without `inboxCaptureEnabled`/`inboxKVNamespaceID` — #587's inbox-capture
            // provisioning doesn't route through here yet. If/when it starts writing an
            // `INBOX_KV` binding via those params elsewhere, this call site needs the same
            // params or it will silently strip that binding on the next worker-composition
            // deploy.
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
            return nil
        } catch {
            return .failed(reason: "couldn't write wrangler.toml: \(error)", exitCode: nil, resources: resources)
        }
    }

    static func readPersistedResources(from siteDirectory: URL) -> WorkerComposition.ProvisionedResources {
        let url = siteDirectory.appendingPathComponent("wrangler.toml")
        guard let toml = try? String(contentsOf: url, encoding: .utf8) else {
            return .init()
        }
        return .init(
            d1DatabaseID: extractTomlString(named: "database_id", from: toml),
            kvNamespaceID: extractTomlString(named: "id", from: toml),
            r2BucketName: extractTomlString(named: "bucket_name", from: toml)
        )
    }

    static func extractResourceID(from output: String) -> String? {
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

    private static func extractTomlString(named key: String, from toml: String) -> String? {
        let escaped = NSRegularExpression.escapedPattern(for: key)
        let pattern = #"(?m)^\s*#(KEY)\s*=\s*"([^"]+)""#.replacingOccurrences(of: "#(KEY)", with: escaped)
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: toml, range: NSRange(toml.startIndex..., in: toml)),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: toml) else {
            return nil
        }
        let value = String(toml[range])
        return value.isEmpty ? nil : value
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
        let reason = HostNodeRetirement.reason("social worker provisioning")
        await LogCenter.shared.append(source: source, stream: .stderr, text: reason)
        return ProcessSupervisor.RunResult(stdout: reason, stderr: "", exitCode: 127)
    }

    public static let defaultDeployer: Deployer = { token, siteID, siteDirectory in
        await DeployCommand(tokenSource: { token }).deploy(siteID: siteID, siteDirectory: siteDirectory)
    }
}

extension SocialWorkerProvisionCommand.Result {
    /// Maps this result onto `DeployCommand.Result`'s shape, dropping the `resources` payload
    /// (no caller surfaces it through this seam) — the shared mapping both `DeployModel.runDeploy`
    /// and `SiteOperations.deployWithWorkerComposition` need after routing every deploy through
    /// `SocialWorkerProvisionCommand.provision`.
    public var asDeployCommandResult: DeployCommand.Result {
        switch self {
        case .succeeded(let url, _, let duration):
            return .succeeded(url: url, duration: duration)
        case .blocked(let failures, let warnings, _):
            return .blocked(failures: failures, warnings: warnings)
        case .workerNameConflict(let name, _):
            return .workerNameConflict(name: name)
        case .failed(let reason, let exitCode, _):
            return .failed(reason: reason, exitCode: exitCode)
        }
    }
}
