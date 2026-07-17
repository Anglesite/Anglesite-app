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
}
