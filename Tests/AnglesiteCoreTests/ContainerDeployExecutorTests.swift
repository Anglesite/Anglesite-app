import Testing
import Foundation
@testable import AnglesiteCore

@Suite("ContainerDeployExecutor")
struct ContainerDeployExecutorTests {

    // MARK: Helpers

    private func makeExecutor(
        fake: FakeLocalContainerControl,
        siteID: String = "site-abc",
        logCenter: LogCenter = LogCenter()
    ) -> ContainerDeployExecutor {
        ContainerDeployExecutor(control: fake, siteID: siteID, logCenter: logCenter)
    }

    private func fakePassing(lines: [String] = []) -> FakeLocalContainerControl {
        FakeLocalContainerControl(
            startResult: .failure(.virtualizationUnavailable),
            execResult: ContainerExecResult(exitCode: 0, stdout: "ok", stderr: ""),
            execStdoutLines: lines
        )
    }

    // MARK: - argv mapping

    @Test("wrangler step sends correct argv")
    func wranglerArgv() async {
        let fake = fakePassing()
        let executor = makeExecutor(fake: fake)
        _ = await executor.run(
            step: .wrangler,
            siteDirectory: URL(fileURLWithPath: "/host/irrelevant"),
            environment: ["CLOUDFLARE_API_TOKEN": "tok123"],
            source: "deploy:site-abc"
        )
        let calls = await fake.execCalls
        #expect(calls.count == 1)
        #expect(calls[0].argv == ["npx", "wrangler", "deploy"])
    }

    @Test("build step sends correct argv")
    func buildArgv() async {
        let fake = fakePassing()
        let executor = makeExecutor(fake: fake)
        _ = await executor.run(
            step: .build,
            siteDirectory: URL(fileURLWithPath: "/host/irrelevant"),
            environment: [:],
            source: "deploy:site-abc:build"
        )
        let calls = await fake.execCalls
        #expect(calls.count == 1)
        #expect(calls[0].argv == ["npm", "run", "build"])
    }

    @Test("preflight step sends correct argv")
    func preflightArgv() async {
        let fake = fakePassing()
        let executor = makeExecutor(fake: fake)
        _ = await executor.run(
            step: .preflight,
            siteDirectory: URL(fileURLWithPath: "/host/irrelevant"),
            environment: [:],
            source: "deploy:site-abc:preflight"
        )
        let calls = await fake.execCalls
        #expect(calls.count == 1)
        #expect(calls[0].argv == ["npx", "tsx", "scripts/pre-deploy-check.ts", "--json"])
    }

    // MARK: - cwd is always /workspace/site

    @Test("exec always uses /workspace/site as working directory")
    func workingDirectory() async {
        let fake = fakePassing()
        let executor = makeExecutor(fake: fake)
        _ = await executor.run(
            step: .build,
            siteDirectory: URL(fileURLWithPath: "/host/totally/different"),
            environment: [:],
            source: "src"
        )
        let calls = await fake.execCalls
        #expect(calls[0].cwd == "/workspace/site")
    }

    // MARK: - CLOUDFLARE_API_TOKEN forwarded, not logged

    @Test("wrangler forwards CLOUDFLARE_API_TOKEN in env")
    func wranglerForwardsToken() async {
        let fake = fakePassing()
        let executor = makeExecutor(fake: fake)
        _ = await executor.run(
            step: .wrangler,
            siteDirectory: URL(fileURLWithPath: "/host/irrelevant"),
            environment: ["CLOUDFLARE_API_TOKEN": "supersecret"],
            source: "deploy:site-abc"
        )
        let calls = await fake.execCalls
        #expect(calls[0].env["CLOUDFLARE_API_TOKEN"] == "supersecret")
    }

    @Test("token does not appear in log output")
    func tokenNotLogged() async {
        let logCenter = LogCenter()
        let fake = FakeLocalContainerControl(
            startResult: .failure(.virtualizationUnavailable),
            execResult: ContainerExecResult(exitCode: 0, stdout: "done", stderr: ""),
            execStdoutLines: ["build complete"]
        )
        let executor = makeExecutor(fake: fake, logCenter: logCenter)
        _ = await executor.run(
            step: .wrangler,
            siteDirectory: URL(fileURLWithPath: "/host/irrelevant"),
            environment: ["CLOUDFLARE_API_TOKEN": "mysecrettoken"],
            source: "deploy:site-abc"
        )
        let snapshot = await logCenter.snapshot()
        for line in snapshot {
            #expect(!line.text.contains("mysecrettoken"))
        }
    }

    // MARK: - stdout lines reach LogCenter

    @Test("stdout lines from exec are appended to LogCenter under source")
    func stdoutToLogCenter() async {
        let logCenter = LogCenter()
        let fake = FakeLocalContainerControl(
            startResult: .failure(.virtualizationUnavailable),
            execResult: ContainerExecResult(exitCode: 0, stdout: "full", stderr: ""),
            execStdoutLines: ["line one", "line two"]
        )
        let executor = makeExecutor(fake: fake, logCenter: logCenter)
        _ = await executor.run(
            step: .build,
            siteDirectory: URL(fileURLWithPath: "/host"),
            environment: [:],
            source: "deploy:site-abc:build"
        )
        let snapshot = await logCenter.snapshot()
        let texts = snapshot
            .filter { $0.source == "deploy:site-abc:build" }
            .map(\.text)
        #expect(texts.contains("line one"))
        #expect(texts.contains("line two"))
    }

    // MARK: - exit code surfaced

    @Test("non-zero exit code surfaces in DeployStepResult")
    func nonZeroExitCode() async {
        let fake = FakeLocalContainerControl(
            startResult: .failure(.virtualizationUnavailable),
            execResult: ContainerExecResult(exitCode: 127, stdout: "not found", stderr: ""),
            execStdoutLines: []
        )
        let executor = makeExecutor(fake: fake)
        let result = await executor.run(
            step: .build,
            siteDirectory: URL(fileURLWithPath: "/host"),
            environment: [:],
            source: "src"
        )
        #expect(result.exitCode == 127)
    }

    @Test("zero exit code surfaces in DeployStepResult")
    func zeroExitCode() async {
        let fake = fakePassing()
        let executor = makeExecutor(fake: fake)
        let result = await executor.run(
            step: .build,
            siteDirectory: URL(fileURLWithPath: "/host"),
            environment: [:],
            source: "src"
        )
        #expect(result.exitCode == 0)
    }

    // MARK: - thrown exec surfaces as nil exitCode

    @Test("thrown exec returns nil exitCode and error message")
    func thrownExecReturnsNilExitCode() async {
        let fake = ThrowingFakeLocalContainerControl()
        let executor = ContainerDeployExecutor(
            control: fake,
            siteID: "site-abc",
            logCenter: LogCenter()
        )
        let result = await executor.run(
            step: .build,
            siteDirectory: URL(fileURLWithPath: "/host"),
            environment: [:],
            source: "src"
        )
        #expect(result.exitCode == nil)
        #expect(result.output.contains("couldn't exec in the container"))
    }

    // MARK: - siteID forwarded to exec

    @Test("siteID is forwarded to exec")
    func siteIDForwarded() async {
        let fake = fakePassing()
        let executor = ContainerDeployExecutor(
            control: fake,
            siteID: "my-special-site",
            logCenter: LogCenter()
        )
        _ = await executor.run(
            step: .build,
            siteDirectory: URL(fileURLWithPath: "/host"),
            environment: [:],
            source: "src"
        )
        let calls = await fake.execCalls
        #expect(calls[0].siteID == "my-special-site")
    }
}

// MARK: - ThrowingFakeLocalContainerControl

private actor ThrowingFakeLocalContainerControl: LocalContainerControl {
    enum ExecError: Error { case boom }

    func start(siteID: String, sourceRepo: URL, ref: String) async throws -> LocalContainerSession {
        throw ExecError.boom
    }
    func stop(siteID: String) async throws {}
    func exec(
        siteID: String,
        argv: [String],
        environment: [String: String],
        workingDirectory: String,
        onOutput: @Sendable (String) -> Void
    ) async throws -> ContainerExecResult {
        throw ExecError.boom
    }
}
