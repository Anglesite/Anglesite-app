import Foundation
import Testing
import AnglesiteCore
@testable import AnglesiteAppCore

private actor GatedDeployExecutor: DeployExecutor {
    private var buildContinuation: CheckedContinuation<Void, Never>?

    func run(
        step: DeployStep,
        siteDirectory: URL,
        environment: [String: String],
        source: String
    ) async -> DeployStepResult {
        switch step {
        case .build:
            await withCheckedContinuation { buildContinuation = $0 }
            return DeployStepResult(exitCode: 0, output: "")
        case .preflight:
            return DeployStepResult(
                exitCode: 0,
                output: #"{"version":1,"ok":true,"failures":[],"warnings":[]}"#
            )
        case .wrangler:
            return DeployStepResult(
                exitCode: 0,
                output: "Published test (0.1 sec)\n  https://test.example.workers.dev"
            )
        }
    }

    func waitUntilBuildIsParked() async {
        while buildContinuation == nil {
            await Task.yield()
        }
    }

    func resumeBuild() {
        buildContinuation?.resume()
        buildContinuation = nil
    }
}

@Suite("DeployModel")
@MainActor
struct DeployModelTests {
    @Test("sudden termination stays disabled until a deploy finishes")
    func suddenTerminationLeaseBracketsDeploy() async {
        let executor = GatedDeployExecutor()
        let controller = SuddenTerminationController(disable: {}, enable: {})
        let command = DeployCommand(tokenSource: { "test-token" }, executor: executor)
        let model = DeployModel(
            command: command,
            logCenter: LogCenter(),
            suddenTerminationController: controller,
            tokenAvailabilityOverride: { true }
        )
        let directory = FileManager.default.temporaryDirectory

        model.deploy(
            siteID: "test-site",
            siteDirectory: directory,
            configDirectory: directory,
            currentRoutes: []
        )
        await executor.waitUntilBuildIsParked()

        #expect(model.isRunning)
        #expect(controller.activeLeaseCount == 1)

        await executor.resumeBuild()
        while model.isRunning {
            await Task.yield()
        }

        #expect(controller.activeLeaseCount == 0)
        guard case .succeeded = model.phase else {
            Issue.record("Expected deploy to succeed, got \(model.phase)")
            return
        }
    }

    @Test("A worker-name conflict parks the deploy and presents the conflict sheet")
    func workerNameConflictParksAndPresents() async {
        let executor = GatedDeployExecutor()
        // Never reached — the conflict short-circuits before the build step — but present so a
        // regression that skips the gate doesn't hang the test on the gated continuation.
        await executor.resumeBuild()
        let command = DeployCommand(
            tokenSource: { "test-token" },
            workerScriptNamesSource: { _ in ["my-site"] },
            executor: executor
        )
        let model = DeployModel(command: command, logCenter: LogCenter(), tokenAvailabilityOverride: { true })
        let siteDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try! FileManager.default.createDirectory(at: siteDir, withIntermediateDirectories: true)
        try! "CF_PROJECT_NAME=my-site\n".write(to: siteDir.appendingPathComponent(".site-config"), atomically: true, encoding: .utf8)

        model.deploy(siteID: "s", siteDirectory: siteDir, configDirectory: siteDir, currentRoutes: [])
        while model.isRunning { await Task.yield() }

        guard case .workerNameConflict(let name) = model.phase else {
            Issue.record("expected .workerNameConflict, got \(model.phase)"); return
        }
        #expect(name == "my-site")
        #expect(model.workerNameConflictPresented)
    }

    @Test("Renaming and retrying rewrites wrangler.toml/.site-config and re-deploys under the new name")
    func renameAndRetrySucceedsUnderNewName() async {
        let executor = GatedDeployExecutor()
        // Never reached — the conflict short-circuits before the build step — but present so a
        // regression that skips the gate doesn't hang the test on the gated continuation.
        await executor.resumeBuild()
        let command = DeployCommand(
            tokenSource: { "test-token" },
            // "my-site" is taken; "my-site-2" (what the sheet will submit) is free.
            workerScriptNamesSource: { _ in ["my-site"] },
            executor: executor
        )
        let model = DeployModel(command: command, logCenter: LogCenter(), tokenAvailabilityOverride: { true })
        let siteDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try! FileManager.default.createDirectory(at: siteDir, withIntermediateDirectories: true)
        try! #"name = "my-site""#.write(to: siteDir.appendingPathComponent("wrangler.toml"), atomically: true, encoding: .utf8)
        try! "CF_PROJECT_NAME=my-site\n".write(to: siteDir.appendingPathComponent(".site-config"), atomically: true, encoding: .utf8)

        model.deploy(siteID: "s", siteDirectory: siteDir, configDirectory: siteDir, currentRoutes: [])
        while model.isRunning { await Task.yield() }
        guard case .workerNameConflict = model.phase else {
            Issue.record("expected .workerNameConflict before renaming, got \(model.phase)"); return
        }

        // Unlike the initial deploy above, the retried deploy's new name is free, so it proceeds
        // into the real pipeline and parks on a fresh build continuation — wait for it, then
        // resume it, mirroring `suddenTerminationLeaseBracketsDeploy`'s synchronization.
        await model.renameWorkerAndRetry("my-site-2")
        await executor.waitUntilBuildIsParked()
        await executor.resumeBuild()
        while model.isRunning { await Task.yield() }

        guard case .succeeded = model.phase else {
            Issue.record("expected .succeeded after rename-and-retry, got \(model.phase)"); return
        }
        #expect(!model.workerNameConflictPresented)
        let toml = try! String(contentsOf: siteDir.appendingPathComponent("wrangler.toml"), encoding: .utf8)
        #expect(toml.contains(#"name = "my-site-2""#))
    }

    @Test("Cancelling the conflict prompt clears the parked deploy and dismisses the sheet")
    func cancelClearsPendingDeploy() async {
        let executor = GatedDeployExecutor()
        await executor.resumeBuild()
        let command = DeployCommand(
            tokenSource: { "test-token" },
            workerScriptNamesSource: { _ in ["my-site"] },
            executor: executor
        )
        let model = DeployModel(command: command, logCenter: LogCenter(), tokenAvailabilityOverride: { true })
        let siteDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try! FileManager.default.createDirectory(at: siteDir, withIntermediateDirectories: true)
        try! "CF_PROJECT_NAME=my-site\n".write(to: siteDir.appendingPathComponent(".site-config"), atomically: true, encoding: .utf8)

        model.deploy(siteID: "s", siteDirectory: siteDir, configDirectory: siteDir, currentRoutes: [])
        while model.isRunning { await Task.yield() }

        model.cancelWorkerNameConflictPrompt()

        #expect(!model.workerNameConflictPresented)
        // A subsequent rename attempt with nothing parked must fail gracefully, not crash.
        await model.renameWorkerAndRetry("anything")
        #expect(!model.isRunning)
        #expect(model.workerNameConflictError == "No deploy is waiting — close this and click Deploy again.")
    }
}
