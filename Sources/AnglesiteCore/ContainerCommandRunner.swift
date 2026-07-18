import Foundation

/// Runs `SocialWorkerProvisionCommand`'s wrangler subcommands (`d1`/`kv`/`r2 create`,
/// `d1 migrations apply`, …) inside a running container via `LocalContainerControl.exec` —
/// the `CommandRunner` counterpart to `ContainerDeployExecutor` (`DeployExecutor.swift:61-168`),
/// which does the same for the three fixed deploy steps. `SocialWorkerProvisionCommand`'s
/// `arguments` are already bare wrangler subcommand argv (e.g. `["d1", "create", name, "--json"]`);
/// this just prefixes `["npx", "wrangler"]` and adapts the result shape.
public struct ContainerCommandRunner: Sendable {
    private let control: any LocalContainerControl
    private let siteID: String
    private let logCenter: LogCenter

    public init(control: any LocalContainerControl, siteID: String, logCenter: LogCenter = .shared) {
        self.control = control
        self.siteID = siteID
        self.logCenter = logCenter
    }

    /// Bind this instance's `run` as a `SocialWorkerProvisionCommand.CommandRunner` closure.
    public var runner: SocialWorkerProvisionCommand.CommandRunner {
        { [self] siteDirectory, arguments, environment, source in
            try await self.run(siteDirectory: siteDirectory, arguments: arguments, environment: environment, source: source)
        }
    }

    // Guest-only allowlist — same rationale as `ContainerDeployExecutor.guestEnvAllowlist`: the
    // host (macOS) environment must never cross into the Linux guest wholesale.
    private static let guestEnvAllowlist: Set<String> = ["CLOUDFLARE_API_TOKEN"]

    private func run(
        siteDirectory: URL,
        arguments: [String],
        environment: [String: String],
        source: String
    ) async throws -> ProcessSupervisor.RunResult {
        let argv = ["npx", "wrangler"] + arguments
        let guestEnvironment = environment.filter { Self.guestEnvAllowlist.contains($0.key) }

        let (lines, continuation) = AsyncStream<(String, LogCenter.Stream)>.makeStream(bufferingPolicy: .unbounded)
        let logCenter = self.logCenter
        let drain = Task.detached(priority: .utility) {
            for await (line, stream) in lines {
                await logCenter.append(source: source, stream: stream, text: line)
            }
        }

        let result: ContainerExecResult
        do {
            result = try await control.exec(
                siteID: siteID,
                argv: argv,
                environment: guestEnvironment,
                workingDirectory: "/workspace/site",
                onOutput: { line, stream in continuation.yield((line, stream)) }
            )
        } catch {
            continuation.finish()
            _ = await drain.value
            throw error
        }
        continuation.finish()
        _ = await drain.value
        return ProcessSupervisor.RunResult(stdout: result.stdout, stderr: result.stderr, exitCode: result.exitCode)
    }
}
