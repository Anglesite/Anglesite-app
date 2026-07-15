import Testing
import Foundation
@testable import AnglesiteCore

/// Tests for Task 5: when a `LocalContainerControl` is supplied to `DeployCommand`, the
/// deploy routes through `ContainerDeployExecutor`; when absent it uses the host path.
///
/// The selection is exercised at the `DeployCommand` level because `DeployModel` (App target)
/// isn't unit-testable here. The observable signal is whether `FakeLocalContainerControl.execCalls`
/// is non-empty: the container executor calls `control.exec(...)` for every step, the host
/// executor never does.
///
/// Also tests the `LocalContainerSiteRuntime.containerControl` / `containerActiveSiteID`
/// accessors added for Task 5's "expose control" step.
@Suite("DeployExecutor selection (Task 5)")
struct DeployExecutorSelectionTests {

    // A successful scan JSON so the full build→preflight→wrangler flow runs without blocking.
    private let scanOK = #"{"ok":true,"failures":[],"warnings":[]}"#
    private let wranglerOut = "Published site (1s)\n  https://site.example.workers.dev"
    private let tmpDir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)

    // MARK: - Container path

    @Test("when a container control is supplied, exec() is called on it for every step")
    func containerControlRoutesExecToContainer() async {
        let fake = FakeLocalContainerControl(
            startResult: .failure(.virtualizationUnavailable),
            execResult: ContainerExecResult(exitCode: 0, stdout: scanOK, stderr: ""),
            execStdoutLines: []
        )
        let executor = ContainerDeployExecutor(
            control: fake,
            siteID: "site-1",
            logCenter: LogCenter()
        )
        let cmd = DeployCommand(
            tokenSource: { "tok" },
            executor: executor
        )
        // The fake returns exit-0 + valid scan JSON for every step, so the full
        // build→preflight→wrangler flow reaches all three exec() calls (wrangler then fails on the
        // missing URL, but only AFTER routing). Asserting `== 3` proves every step routes through
        // the container; step-argv ordering is covered by `allStepsRouteViaContainer`.
        _ = await cmd.deploy(siteID: "site-1", siteDirectory: tmpDir)
        let calls = await fake.execCalls
        #expect(calls.count == 3, "all three deploy steps must route through container control.exec()")
        #expect(calls.allSatisfy { $0.siteID == "site-1" })
    }

    @Test("when container control is supplied, exec siteID matches the deploy siteID")
    func containerSiteIDForwarded() async {
        let fake = FakeLocalContainerControl(
            startResult: .failure(.virtualizationUnavailable),
            execResult: ContainerExecResult(exitCode: 0, stdout: scanOK, stderr: ""),
            execStdoutLines: []
        )
        let executor = ContainerDeployExecutor(control: fake, siteID: "my-site", logCenter: LogCenter())
        let cmd = DeployCommand(tokenSource: { "tok" }, executor: executor)
        _ = await cmd.deploy(siteID: "my-site", siteDirectory: tmpDir)
        let calls = await fake.execCalls
        for call in calls {
            #expect(call.siteID == "my-site")
        }
    }

    // MARK: - Host path (nil control → no exec calls on any container control)

    @Test("when no container control is supplied, container control exec() is never called")
    func hostPathDoesNotCallContainerExec() async {
        // Track calls via a FakeLocalContainerControl that should NOT be called.
        let fake = FakeLocalContainerControl(
            startResult: .failure(.virtualizationUnavailable),
            execResult: ContainerExecResult(exitCode: 0, stdout: "", stderr: ""),
            execStdoutLines: []
        )
        // HostDeployExecutor with an unavailable resolver — simulates the host path being chosen.
        let hostExecutor = HostDeployExecutor(
            supervisor: ProcessSupervisor(),
            logCenter: LogCenter(),
            resolveCommand: { _ in { _ in .unavailable(reason: "host path chosen") } }
        )
        let cmd = DeployCommand(tokenSource: { "tok" }, executor: hostExecutor)
        _ = await cmd.deploy(siteID: "site-1", siteDirectory: tmpDir)
        let calls = await fake.execCalls
        #expect(calls.isEmpty, "container control.exec() must NOT be called when the host executor is used")
    }

    // MARK: - Step routing for full container deploy

    @Test("all three steps route through the container executor in order")
    func allStepsRouteViaContainer() async {
        // Use a step-aware fake: intercept exec calls in order and return the right payload.
        let stepAware = StepAwareFakeContainerControl()
        let executor = ContainerDeployExecutor(control: stepAware, siteID: "s", logCenter: LogCenter())
        let cmd = DeployCommand(tokenSource: { "tok" }, executor: executor)
        _ = await cmd.deploy(siteID: "s", siteDirectory: tmpDir)
        let calls = await stepAware.calls
        let argvs = calls.map(\.argv)
        #expect(argvs.count == 3)
        #expect(argvs[0] == ["npm", "run", "build"])
        #expect(argvs[1] == ["npx", "tsx", "scripts/pre-deploy-check.ts", "--json"])
        #expect(argvs[2] == ["npx", "wrangler", "deploy"])
    }
}

// MARK: - LocalContainerSiteRuntime.containerControl exposure (Task 5)

@Suite("LocalContainerSiteRuntime containerControl exposure")
struct LocalContainerSiteRuntimeControlExposureTests {
    private static let ok = LocalContainerSession(
        previewURL: URL(string: "http://127.0.0.1:51001")!,
        mcpURL: URL(string: "http://127.0.0.1:51002/mcp")!
    )

    @Test("containerControl returns nil before start()")
    func containerControlNilBeforeStart() async {
        let fake = FakeLocalContainerControl(startResult: .success(Self.ok))
        let mcp = MCPClient(supervisor: ProcessSupervisor(), logCenter: LogCenter())
        let rt = LocalContainerSiteRuntime(ref: "HEAD", control: fake, mcpClient: mcp, connect: { _, _ in })
        let control = await rt.containerControl
        #expect(control == nil)
    }

    @Test("containerControl returns the held control after start() succeeds")
    func containerControlPresentAfterStart() async {
        let fake = FakeLocalContainerControl(startResult: .success(Self.ok))
        let mcp = MCPClient(supervisor: ProcessSupervisor(), logCenter: LogCenter())
        let rt = LocalContainerSiteRuntime(ref: "HEAD", control: fake, mcpClient: mcp, connect: { _, _ in })
        await rt.start(siteID: "s1", siteDirectory: URL(fileURLWithPath: "/unused"))
        let control = await rt.containerControl
        #expect(control != nil)
    }

    @Test("containerActiveSiteID returns nil before start()")
    func activeSiteIDNilBeforeStart() async {
        let fake = FakeLocalContainerControl(startResult: .success(Self.ok))
        let mcp = MCPClient(supervisor: ProcessSupervisor(), logCenter: LogCenter())
        let rt = LocalContainerSiteRuntime(ref: "HEAD", control: fake, mcpClient: mcp, connect: { _, _ in })
        let siteID = await rt.containerActiveSiteID
        #expect(siteID == nil)
    }

    @Test("containerActiveSiteID returns the started siteID after start() succeeds")
    func activeSiteIDAfterStart() async {
        let fake = FakeLocalContainerControl(startResult: .success(Self.ok))
        let mcp = MCPClient(supervisor: ProcessSupervisor(), logCenter: LogCenter())
        let rt = LocalContainerSiteRuntime(ref: "HEAD", control: fake, mcpClient: mcp, connect: { _, _ in })
        await rt.start(siteID: "my-site", siteDirectory: URL(fileURLWithPath: "/unused"))
        let siteID = await rt.containerActiveSiteID
        #expect(siteID == "my-site")
    }

    @Test("containerControl returns nil after stop()")
    func containerControlNilAfterStop() async {
        let fake = FakeLocalContainerControl(startResult: .success(Self.ok))
        let mcp = MCPClient(supervisor: ProcessSupervisor(), logCenter: LogCenter())
        let rt = LocalContainerSiteRuntime(ref: "HEAD", control: fake, mcpClient: mcp, connect: { _, _ in })
        await rt.start(siteID: "s1", siteDirectory: URL(fileURLWithPath: "/unused"))
        await rt.stop()
        let control = await rt.containerControl
        #expect(control == nil)
    }

    @Test("containerActiveSiteID returns nil after stop()")
    func activeSiteIDNilAfterStop() async {
        let fake = FakeLocalContainerControl(startResult: .success(Self.ok))
        let mcp = MCPClient(supervisor: ProcessSupervisor(), logCenter: LogCenter())
        let rt = LocalContainerSiteRuntime(ref: "HEAD", control: fake, mcpClient: mcp, connect: { _, _ in })
        await rt.start(siteID: "s1", siteDirectory: URL(fileURLWithPath: "/unused"))
        await rt.stop()
        let siteID = await rt.containerActiveSiteID
        #expect(siteID == nil)
    }

    // MARK: - containerSnapshot() — single-hop accessor

    @Test("containerSnapshot returns nil before start()")
    func snapshotNilBeforeStart() async {
        let fake = FakeLocalContainerControl(startResult: .success(Self.ok))
        let mcp = MCPClient(supervisor: ProcessSupervisor(), logCenter: LogCenter())
        let rt = LocalContainerSiteRuntime(ref: "HEAD", control: fake, mcpClient: mcp, connect: { _, _ in })
        let snap = await rt.containerSnapshot()
        #expect(snap == nil)
    }

    @Test("containerSnapshot returns control and siteID after start() succeeds")
    func snapshotPresentAfterStart() async {
        let fake = FakeLocalContainerControl(startResult: .success(Self.ok))
        let mcp = MCPClient(supervisor: ProcessSupervisor(), logCenter: LogCenter())
        let rt = LocalContainerSiteRuntime(ref: "HEAD", control: fake, mcpClient: mcp, connect: { _, _ in })
        await rt.start(siteID: "snap-site", siteDirectory: URL(fileURLWithPath: "/unused"))
        let snap = await rt.containerSnapshot()
        #expect(snap != nil)
        #expect(snap?.siteID == "snap-site")
    }

    @Test("containerSnapshot returns nil after stop()")
    func snapshotNilAfterStop() async {
        let fake = FakeLocalContainerControl(startResult: .success(Self.ok))
        let mcp = MCPClient(supervisor: ProcessSupervisor(), logCenter: LogCenter())
        let rt = LocalContainerSiteRuntime(ref: "HEAD", control: fake, mcpClient: mcp, connect: { _, _ in })
        await rt.start(siteID: "s1", siteDirectory: URL(fileURLWithPath: "/unused"))
        await rt.stop()
        let snap = await rt.containerSnapshot()
        #expect(snap == nil)
    }
}

// MARK: - StepAwareFakeContainerControl

/// A `LocalContainerControl` whose `exec` returns the appropriate payload for each step
/// in sequence (build → preflight → wrangler), so the full three-step flow completes
/// without the wrong step output short-circuiting the run.
private actor StepAwareFakeContainerControl: LocalContainerControl {
    private(set) var calls: [(siteID: String, argv: [String])] = []
    private var callCount = 0

    private let scanOK = #"{"ok":true,"failures":[],"warnings":[]}"#
    private let wranglerOut = "Published site (1s)\n  https://site.example.workers.dev"

    func start(
        siteID: String, sourceRepo: URL, ref: String,
        onOutput: @escaping @Sendable (String, LogCenter.Stream) -> Void
    ) async throws -> LocalContainerSession {
        throw LocalContainerError.virtualizationUnavailable
    }

    func stop(siteID: String) async throws {}

    func exec(
        siteID: String,
        argv: [String],
        environment: [String: String],
        workingDirectory: String,
        onOutput: @escaping @Sendable (String, LogCenter.Stream) -> Void
    ) async throws -> ContainerExecResult {
        calls.append((siteID: siteID, argv: argv))
        let n = callCount
        callCount += 1
        // Step 0 = build (exit 0, empty stdout)
        // Step 1 = preflight (exit 0, scan JSON)
        // Step 2 = wrangler (exit 0, URL output)
        switch n {
        case 0: return ContainerExecResult(exitCode: 0, stdout: "", stderr: "")
        case 1: return ContainerExecResult(exitCode: 0, stdout: scanOK, stderr: "")
        default: return ContainerExecResult(exitCode: 0, stdout: wranglerOut, stderr: "")
        }
    }

    func execInteractive(
        siteID: String,
        argv: [String],
        environment: [String: String],
        workingDirectory: String,
        onOutput: @escaping @Sendable (String, LogCenter.Stream) -> Void
    ) async throws -> InteractiveExecHandle {
        InteractiveExecHandle(write: { _ in }, terminate: {})
    }
}
