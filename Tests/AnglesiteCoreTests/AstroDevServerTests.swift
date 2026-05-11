import XCTest
@testable import AnglesiteCore

final class AstroDevServerTests: XCTestCase {
    // MARK: parseReadyURL

    func testParseReadyURLMatchesAstroLocalLine() {
        let url = AstroDevServer.parseReadyURL("  ┃ Local    http://localhost:4321/")
        XCTAssertEqual(url, URL(string: "http://localhost:4321/"))
    }

    func testParseReadyURLMatchesPlainLine() {
        let url = AstroDevServer.parseReadyURL("Local: http://127.0.0.1:8080/")
        XCTAssertEqual(url, URL(string: "http://127.0.0.1:8080/"))
    }

    func testParseReadyURLIgnoresNonURLLines() {
        XCTAssertNil(AstroDevServer.parseReadyURL("astro v5.0.0 ready in 320 ms"))
        XCTAssertNil(AstroDevServer.parseReadyURL(""))
    }

    func testParseReadyURLStripsANSIEscapes() {
        // ESC [32m Local ESC [0m http://localhost:4321/
        let coloured = "\u{1B}[32mLocal\u{1B}[0m  http://localhost:4321/"
        let url = AstroDevServer.parseReadyURL(coloured)
        XCTAssertEqual(url, URL(string: "http://localhost:4321/"))
    }

    // MARK: start / stop against a fake server fixture

    func testStartResolvesWhenFakeServerPrintsReadyURL() async throws {
        let supervisor = ProcessSupervisor()
        let center = LogCenter()
        let server = AstroDevServer(supervisor: supervisor, logCenter: center)

        let url = try await server.start(
            siteDirectory: URL(fileURLWithPath: "/tmp"),
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "echo '  Local    http://localhost:4321/'; exec sleep 30"],
            source: "astro-test",
            readyTimeout: 5
        )

        XCTAssertEqual(url, URL(string: "http://localhost:4321/"))
        let running = await server.isRunning
        XCTAssertTrue(running)

        await server.stop(timeout: 2)
        let runningAfter = await server.isRunning
        XCTAssertFalse(runningAfter)
    }

    func testStartTimesOutWhenReadyLineNeverArrives() async throws {
        let supervisor = ProcessSupervisor()
        let center = LogCenter()
        let server = AstroDevServer(supervisor: supervisor, logCenter: center)

        do {
            _ = try await server.start(
                siteDirectory: URL(fileURLWithPath: "/tmp"),
                executable: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", "exec sleep 30"],
                source: "astro-timeout",
                readyTimeout: 0.3
            )
            XCTFail("expected timeout")
        } catch AstroDevServer.AstroError.readyTimeout {
            // expected
        } catch {
            XCTFail("unexpected error: \(error)")
        }
        // After a timeout the handle is cleared so a new start can be attempted.
        let isRunning = await server.isRunning
        XCTAssertFalse(isRunning)
    }

    func testStartFailsWhenServerExitsBeforeReady() async throws {
        let supervisor = ProcessSupervisor()
        let center = LogCenter()
        let server = AstroDevServer(supervisor: supervisor, logCenter: center)

        do {
            _ = try await server.start(
                siteDirectory: URL(fileURLWithPath: "/tmp"),
                executable: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", "echo nothing-useful; exit 1"],
                source: "astro-crash",
                readyTimeout: 5
            )
            XCTFail("expected exitedBeforeReady")
        } catch AstroDevServer.AstroError.exitedBeforeReady(let reason) {
            XCTAssertEqual(reason, .exited(code: 1))
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testStartRejectsSecondConcurrentStart() async throws {
        let supervisor = ProcessSupervisor()
        let center = LogCenter()
        let server = AstroDevServer(supervisor: supervisor, logCenter: center)

        _ = try await server.start(
            siteDirectory: URL(fileURLWithPath: "/tmp"),
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "echo '  Local    http://localhost:4321/'; exec sleep 30"],
            source: "astro-concurrent",
            readyTimeout: 5
        )
        do {
            _ = try await server.start(
                siteDirectory: URL(fileURLWithPath: "/tmp"),
                executable: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", "exec sleep 30"],
                source: "astro-concurrent-2"
            )
            XCTFail("expected alreadyRunning")
        } catch AstroDevServer.AstroError.alreadyRunning {
            // expected
        } catch {
            XCTFail("unexpected error: \(error)")
        }
        await server.stop(timeout: 2)
    }
}
