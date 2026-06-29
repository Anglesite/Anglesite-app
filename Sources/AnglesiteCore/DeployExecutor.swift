import Foundation

// MARK: - Types

/// Identifies one logical step in the deploy sequence.
public enum DeployStep: Sendable {
    /// `npm run build` — produces `dist/`.
    case build
    /// `npx tsx scripts/pre-deploy-check.ts --json` — the bundled plugin's security scan.
    case preflight
    /// `wrangler deploy` — publishes the built site to Cloudflare Workers.
    case wrangler
}

/// The result of running a single deploy step.
///
/// - `exitCode`: the process exit code, or `nil` for pre-spawn failures (resolver reported
///   `.unavailable`, or the process could not be spawned at all). Mirrors the `exitCode`
///   convention in `DeployCommand.Result.failed`.
/// - `output`: captured stdout, used for URL/scan parsing by the caller. Also streamed
///   line-by-line to `LogCenter` under the caller-supplied source during execution.
public struct DeployStepResult: Sendable, Equatable {
    public let exitCode: Int32?
    public let output: String

    public init(exitCode: Int32?, output: String) {
        self.exitCode = exitCode
        self.output = output
    }
}

// MARK: - Protocol

/// Abstraction over the execution substrate for one deploy step.
///
/// `HostDeployExecutor` is the concrete implementation for the embedded-Node (host) path.
/// A future `ContainerDeployExecutor` will implement this for the in-container path.
///
/// The `source` parameter is the `LogCenter` source tag (e.g. `"deploy:<id>:build"`,
/// `"deploy:<id>"`). Callers supply it so the right log row receives the output.
public protocol DeployExecutor: Sendable {
    func run(
        step: DeployStep,
        siteDirectory: URL,
        environment: [String: String],
        source: String
    ) async -> DeployStepResult
}

// MARK: - ContainerDeployExecutor

/// Runs deploy steps inside a running container via `LocalContainerControl.exec`.
///
/// The site is cloned to `/workspace/site` in the guest at boot time; Node 22 and the
/// site's `node_modules` are already installed there. Each step is mapped to an in-guest
/// argv and executed at that working directory.
///
/// `CLOUDFLARE_API_TOKEN` is forwarded through the `environment` dict that the caller
/// supplies — it is never added here and never written to logs.
public struct ContainerDeployExecutor: DeployExecutor {
    private let control: any LocalContainerControl
    private let siteID: String
    private let logCenter: LogCenter

    public init(
        control: any LocalContainerControl,
        siteID: String,
        logCenter: LogCenter = .shared
    ) {
        self.control = control
        self.siteID = siteID
        self.logCenter = logCenter
    }

    // MARK: DeployExecutor

    public func run(
        step: DeployStep,
        siteDirectory: URL,
        environment: [String: String],
        source: String
    ) async -> DeployStepResult {
        // `siteDirectory` is the HOST path — the guest always uses /workspace/site.
        let argv = guestArgv(for: step)
        // Stream guest output to LogCenter LIVE (matching the host path): the sync `onOutput`
        // callback yields each line into an AsyncStream (`yield` is nonisolated + Sendable, so it's
        // safe from the @Sendable closure), and a structured `async let` drains it concurrently,
        // appending to the actor-isolated LogCenter. The `continuation.finish()` + `await drained`
        // before returning guarantees no trailing line is lost — the same contract
        // `InProcessBackend` uses for the host streaming.
        // Never log the environment dict — CLOUDFLARE_API_TOKEN stays off disk and out of logs.
        let (lines, continuation) = AsyncStream<String>.makeStream(bufferingPolicy: .unbounded)
        async let drained: Void = {
            for await line in lines {
                await logCenter.append(source: source, stream: .stdout, text: line)
            }
        }()
        let result: ContainerExecResult
        do {
            result = try await control.exec(
                siteID: siteID,
                argv: argv,
                environment: Self.guestEnvironment(from: environment),
                workingDirectory: "/workspace/site",
                onOutput: { line in continuation.yield(line) }
            )
        } catch {
            continuation.finish()
            await drained
            return DeployStepResult(exitCode: nil, output: "couldn't exec in the container: \(error)")
        }
        continuation.finish()
        await drained
        return DeployStepResult(exitCode: result.exitCode, output: result.stdout)
    }

    /// `DeployCommand` hands every step the full HOST (macOS) environment; almost none of it is valid
    /// in the Linux guest. We must NOT forward it wholesale: the host `PATH` (`/opt/homebrew/bin:…`)
    /// would shadow the guest's Linux PATH and break `node`/`npm`/`wrangler` resolution, and
    /// `HOME`/`TMPDIR`/`XPC_*`/`__CF*` are host-only noise. The guest provides its own PATH/HOME; the
    /// only host-originated value the deploy needs across the boundary is the Cloudflare token. Keep
    /// this allowlist tight — add a key only when a deploy step demonstrably needs it in-guest.
    private static let guestEnvAllowlist: Set<String> = ["CLOUDFLARE_API_TOKEN"]

    private static func guestEnvironment(from hostEnvironment: [String: String]) -> [String: String] {
        hostEnvironment.filter { guestEnvAllowlist.contains($0.key) }
    }

    // MARK: argv mapping

    private func guestArgv(for step: DeployStep) -> [String] {
        switch step {
        case .build:
            return ["npm", "run", "build"]
        case .preflight:
            return ["npx", "tsx", "scripts/pre-deploy-check.ts", "--json"]
        case .wrangler:
            return ["npx", "wrangler", "deploy"]
        }
    }
}

// MARK: - HostDeployExecutor

/// Runs deploy steps on the host using the embedded Node runtime, mirroring `DeployCommand`'s
/// existing inline spawn logic.
///
/// Injecting a custom `resolveCommand` lets tests drive arbitrary shell fixtures without
/// requiring the vendored Node bundle to be present (same pattern as `DeployCommand`'s
/// `CommandResolver`/`PreflightChecker` injection).
///
/// Normally (i.e. not in tests) the default resolver chooses the host command per step:
///   - `.build`    → `node npm run build`  (vendored npm)
///   - `.preflight`→ `/usr/bin/env npx tsx scripts/pre-deploy-check.ts --json`
///   - `.wrangler` → `node node_modules/.bin/wrangler deploy`
///
/// Output is streamed line-by-line to `logCenter` under `source` *and* accumulated into
/// `DeployStepResult.output` so callers can parse the deployed URL or scan JSON.
public struct HostDeployExecutor: DeployExecutor {
    private let supervisor: ProcessSupervisor
    private let logCenter: LogCenter
    /// Injectable per-step command resolver. Defaults to `HostDeployExecutor.defaultResolver`.
    private let resolveCommand: @Sendable (DeployStep) -> DeployCommand.CommandResolver

    public init(
        supervisor: ProcessSupervisor = .shared,
        logCenter: LogCenter = .shared,
        resolveCommand: @escaping @Sendable (DeployStep) -> DeployCommand.CommandResolver =
            HostDeployExecutor.defaultResolver
    ) {
        self.supervisor = supervisor
        self.logCenter = logCenter
        self.resolveCommand = resolveCommand
    }

    // MARK: DeployExecutor

    public func run(
        step: DeployStep,
        siteDirectory: URL,
        environment: [String: String],
        source: String
    ) async -> DeployStepResult {
        let resolver = resolveCommand(step)
        let plan = resolver(siteDirectory)

        switch plan {
        case .unavailable(let reason):
            return DeployStepResult(exitCode: nil, output: reason)
        case .run(let executable, let arguments):
            return await spawn(
                executable: executable,
                arguments: arguments,
                environment: environment,
                siteDirectory: siteDirectory,
                source: source
            )
        }
    }

    // MARK: Spawn helpers

    private func spawn(
        executable: URL,
        arguments: [String],
        environment: [String: String],
        siteDirectory: URL,
        source: String
    ) async -> DeployStepResult {
        let handle: ProcessSupervisor.Handle
        do {
            handle = try await supervisor.launch(
                source: source,
                executable: executable,
                arguments: arguments,
                environment: environment,
                currentDirectoryURL: siteDirectory,
                logCenter: logCenter
            )
        } catch {
            return DeployStepResult(exitCode: nil, output: "couldn't spawn process: \(error)")
        }

        let reason = await withTaskCancellationHandler {
            await supervisor.waitForExit(handle)
        } onCancel: {
            Task { await supervisor.terminate(handle) }
        }

        // Snapshot stdout from LogCenter — identical to DeployCommand's approach.
        let snapshot = await logCenter.snapshot()
        let output = snapshot
            .filter { $0.source == source && $0.stream == .stdout }
            .map(\.text)
            .joined(separator: "\n")

        switch reason {
        case .exited(let code):
            return DeployStepResult(exitCode: code, output: output)
        case .terminated:
            return DeployStepResult(exitCode: nil, output: output)
        case .retriesExhausted(let lastCode):
            return DeployStepResult(exitCode: lastCode, output: output)
        }
    }

    // MARK: Default command resolvers

    /// Returns the appropriate `CommandResolver` for each step, mirroring `DeployCommand`'s
    /// static resolvers exactly.
    public static let defaultResolver: @Sendable (DeployStep) -> DeployCommand.CommandResolver = { step in
        switch step {
        case .build:
            return DeployCommand.resolveBuildCommand
        case .preflight:
            return preflightResolver
        case .wrangler:
            return DeployCommand.resolveWranglerCommand
        }
    }

    /// Resolves the preflight command: `/usr/bin/env npx tsx scripts/pre-deploy-check.ts --json`.
    /// Mirrors the inline resolve inside `DeployCommand.defaultPreflight`.
    public static let preflightResolver: DeployCommand.CommandResolver = { siteDirectory in
        let scriptPath = siteDirectory
            .appendingPathComponent("scripts/pre-deploy-check.ts")
            .path
        return .run(
            executable: URL(fileURLWithPath: "/usr/bin/env"),
            arguments: ["npx", "tsx", scriptPath, "--json"]
        )
    }
}
