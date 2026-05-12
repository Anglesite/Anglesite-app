import XCTest
@testable import AnglesiteCore

final class PreviewSessionTests: XCTestCase {
    private let alwaysReady: AstroDevServer.ReadinessProbe = { _ in true }
    /// A real, existing directory — the supervisor `cd`s into the site dir before spawning, so a
    /// nonexistent path would fail `process.run()` before our fixture script even runs.
    private let tmpDir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)

    private func makeSession(
        resolve: @escaping PreviewSession.CommandResolver,
        probe: @escaping AstroDevServer.ReadinessProbe
    ) -> PreviewSession {
        let supervisor = ProcessSupervisor()
        let center = LogCenter()
        let devServer = AstroDevServer(supervisor: supervisor, logCenter: center, readinessProbe: probe)
        return PreviewSession(devServer: devServer, logCenter: center, resolveCommand: resolve)
    }

    private func shFixture(_ script: String, _ args: String...) -> PreviewSession.LaunchPlan {
        .run(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", script] + args)
    }

    func testUnavailableCommandLandsInFailed() async {
        let session = makeSession(
            resolve: { _ in .unavailable(reason: "dependencies not installed — run `npm install`") },
            probe: alwaysReady
        )
        await session.start(siteID: "mysite", siteDirectory: tmpDir)
        let state = await session.state
        XCTAssertEqual(state, .failed(siteID: "mysite", message: "dependencies not installed — run `npm install`"))
    }

    func testRunnableCommandReachesReadyThenStopReturnsToIdle() async {
        let session = makeSession(
            resolve: { _ in self.shFixture("echo '  Local    http://localhost:4321/'; exec sleep 30") },
            probe: alwaysReady
        )
        await session.start(siteID: "mysite", siteDirectory: tmpDir)
        let ready = await session.state
        XCTAssertEqual(ready, .ready(siteID: "mysite", url: URL(string: "http://localhost:4321/")!))

        await session.stop()
        let idle = await session.state
        XCTAssertEqual(idle, .idle)
    }

    func testCrashBeforeReadyLandsInFailed() async {
        let session = makeSession(
            resolve: { _ in self.shFixture("echo broken 1>&2; exit 1") },
            probe: alwaysReady
        )
        await session.start(
            siteID: "mysite",
            siteDirectory: tmpDir,
            restartPolicy: .never
        )
        let state = await session.state
        guard case .failed(let siteID, _) = state else {
            return XCTFail("expected .failed, got \(state)")
        }
        XCTAssertEqual(siteID, "mysite")
    }

    func testReadyURLUpdatesWhenADevServerRestartPicksANewPort() async throws {
        let counter = NSTemporaryDirectory() + "preview-restart-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: counter) }
        let script = """
        f="$0"
        n=$(cat "$f" 2>/dev/null || echo 0); n=$((n+1)); echo "$n" > "$f"
        echo "  Local    http://localhost:920$n/"
        if [ "$n" -lt 2 ]; then sleep 0.2; exit 1; fi
        exec sleep 30
        """
        let session = makeSession(
            resolve: { _ in self.shFixture(script, counter) },
            probe: alwaysReady
        )
        await session.start(
            siteID: "mysite",
            siteDirectory: tmpDir,
            restartPolicy: .onCrash(maxAttempts: 3, baseBackoff: 0.05)
        )
        let first = await session.state
        XCTAssertEqual(first, .ready(siteID: "mysite", url: URL(string: "http://localhost:9201/")!))

        try? await Task.sleep(nanoseconds: 700_000_000)
        let updated = await session.state
        XCTAssertEqual(updated, .ready(siteID: "mysite", url: URL(string: "http://localhost:9202/")!))

        await session.stop()
    }

    func testObserveStreamEmitsIdleStartingReady() async {
        let session = makeSession(
            resolve: { _ in self.shFixture("echo '  Local    http://localhost:4321/'; exec sleep 30") },
            probe: alwaysReady
        )
        let stream = await session.observe()
        var iterator = stream.makeAsyncIterator()

        // First emission is the current state (idle), before we start.
        let s0 = await iterator.next()
        XCTAssertEqual(s0, .idle)

        await session.start(siteID: "mysite", siteDirectory: tmpDir)

        // Collect the remaining transitions until we see .ready.
        var seen: [PreviewSession.State] = []
        while let s = await iterator.next() {
            seen.append(s)
            if case .ready = s { break }
        }
        XCTAssertEqual(seen.first, .starting(siteID: "mysite"))
        XCTAssertEqual(seen.last, .ready(siteID: "mysite", url: URL(string: "http://localhost:4321/")!))

        await session.stop()
    }
}
