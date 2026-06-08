import Testing
import Foundation
@testable import AnglesiteCore

struct AstroDevServerTests {
    /// A readiness probe that always reports the server is up — used by the log-only fixtures
    /// below, which print a `Local …` line but don't actually bind a port.
    private let alwaysReady: AstroDevServer.ReadinessProbe = { _ in true }

    // MARK: parseReadyURL

    @Test func `Parse ready URL matches Astro Local line`() {
        let url = AstroDevServer.parseReadyURL("  ┃ Local    http://localhost:4321/")
        #expect(url == URL(string: "http://localhost:4321/"))
    }

    @Test func `Parse ready URL matches plain line`() {
        let url = AstroDevServer.parseReadyURL("Local: http://127.0.0.1:8080/")
        #expect(url == URL(string: "http://127.0.0.1:8080/"))
    }

    @Test func `Parse ready URL ignores non-URL lines`() {
        #expect(AstroDevServer.parseReadyURL("astro v5.0.0 ready in 320 ms") == nil)
        #expect(AstroDevServer.parseReadyURL("") == nil)
    }

    @Test func `Parse ready URL strips ANSI escapes`() {
        // ESC [32m Local ESC [0m http://localhost:4321/
        let coloured = "\u{1B}[32mLocal\u{1B}[0m  http://localhost:4321/"
        let url = AstroDevServer.parseReadyURL(coloured)
        #expect(url == URL(string: "http://localhost:4321/"))
    }

    // MARK: start / stop against a fake server fixture

    @Test func `Start resolves when fake server prints ready URL`() async throws {
        let supervisor = ProcessSupervisor()
        let center = LogCenter()
        let server = AstroDevServer(supervisor: supervisor, logCenter: center, readinessProbe: alwaysReady)

        let url = try await server.start(
            siteDirectory: URL(fileURLWithPath: "/tmp"),
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "echo '  Local    http://localhost:4321/'; exec sleep 30"],
            source: "astro-test",
            readyTimeout: 5
        )

        #expect(url == URL(string: "http://localhost:4321/"))
        let running = await server.isRunning
        #expect(running)

        await server.stop(timeout: 2)
        let runningAfter = await server.isRunning
        #expect(!runningAfter)
    }

    @Test func `Start times out when ready line never arrives`() async throws {
        let supervisor = ProcessSupervisor()
        let center = LogCenter()
        let server = AstroDevServer(supervisor: supervisor, logCenter: center, readinessProbe: alwaysReady)

        await #expect(throws: AstroDevServer.AstroError.readyTimeout) {
            _ = try await server.start(
                siteDirectory: URL(fileURLWithPath: "/tmp"),
                executable: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", "exec sleep 30"],
                source: "astro-timeout",
                readyTimeout: 0.3
            )
        }
        // After a timeout the handle is cleared so a new start can be attempted.
        let isRunning = await server.isRunning
        #expect(!isRunning)
    }

    @Test func `Start fails when server exits before ready`() async throws {
        let supervisor = ProcessSupervisor()
        let center = LogCenter()
        let server = AstroDevServer(supervisor: supervisor, logCenter: center, readinessProbe: alwaysReady)

        await #expect(throws: AstroDevServer.AstroError.exitedBeforeReady(.exited(code: 1))) {
            _ = try await server.start(
                siteDirectory: URL(fileURLWithPath: "/tmp"),
                executable: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", "echo nothing-useful; exit 1"],
                source: "astro-crash",
                restartPolicy: .never,
                readyTimeout: 5
            )
        }
    }

    @Test func `Start gives up when server crash-loops before ready`() async throws {
        let supervisor = ProcessSupervisor()
        let center = LogCenter()
        let server = AstroDevServer(supervisor: supervisor, logCenter: center, readinessProbe: alwaysReady)

        await #expect(throws: AstroDevServer.AstroError.exitedBeforeReady(.retriesExhausted(lastCode: 1))) {
            _ = try await server.start(
                siteDirectory: URL(fileURLWithPath: "/tmp"),
                executable: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", "echo broken-config 1>&2; exit 1"],
                source: "astro-crashloop",
                restartPolicy: .onCrash(maxAttempts: 2, baseBackoff: 0.0),
                readyTimeout: 5
            )
        }
        let isRunning = await server.isRunning
        #expect(!isRunning)
    }

    @Test func `Start rejects second concurrent start`() async throws {
        let supervisor = ProcessSupervisor()
        let center = LogCenter()
        let server = AstroDevServer(supervisor: supervisor, logCenter: center, readinessProbe: alwaysReady)

        _ = try await server.start(
            siteDirectory: URL(fileURLWithPath: "/tmp"),
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "echo '  Local    http://localhost:4321/'; exec sleep 30"],
            source: "astro-concurrent",
            readyTimeout: 5
        )
        await #expect(throws: AstroDevServer.AstroError.alreadyRunning) {
            _ = try await server.start(
                siteDirectory: URL(fileURLWithPath: "/tmp"),
                executable: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", "exec sleep 30"],
                source: "astro-concurrent-2"
            )
        }
        await server.stop(timeout: 2)
    }

    // MARK: HTTP readiness probe

    @Test func `Start waits for readiness probe to succeed`() async throws {
        let supervisor = ProcessSupervisor()
        let center = LogCenter()

        // Probe fails the first two times, then succeeds — modelling Astro logging "Local …"
        // a beat before the HTTP server is actually accepting connections.
        let attempts = ProbeCounter()
        let probe: AstroDevServer.ReadinessProbe = { _ in
            await attempts.bump() >= 3
        }
        let server = AstroDevServer(supervisor: supervisor, logCenter: center, readinessProbe: probe)

        let url = try await server.start(
            siteDirectory: URL(fileURLWithPath: "/tmp"),
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "echo '  Local    http://localhost:4321/'; exec sleep 30"],
            source: "astro-probe",
            readyTimeout: 10
        )
        #expect(url == URL(string: "http://localhost:4321/"))
        let count = await attempts.value
        #expect(count >= 3)

        await server.stop(timeout: 2)
    }

    // MARK: restart handling

    @Test func `Ready URL updates after supervised restart`() async throws {
        let supervisor = ProcessSupervisor()
        let center = LogCenter()
        let server = AstroDevServer(supervisor: supervisor, logCenter: center, readinessProbe: alwaysReady)

        // Counter file: run #1 prints :9001/ then crashes; run #2 prints :9002/ then sleeps.
        let counter = NSTemporaryDirectory() + "astro-restart-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: counter) }
        let script = """
        f="$0"
        n=$(cat "$f" 2>/dev/null || echo 0); n=$((n+1)); echo "$n" > "$f"
        echo "  Local    http://localhost:900$n/"
        if [ "$n" -lt 2 ]; then sleep 0.2; exit 1; fi
        exec sleep 30
        """

        let first = try await server.start(
            siteDirectory: URL(fileURLWithPath: "/tmp"),
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", script, counter],
            source: "astro-restart",
            restartPolicy: .onCrash(maxAttempts: 3, baseBackoff: 0.05),
            readyTimeout: 5
        )
        #expect(first == URL(string: "http://localhost:9001/"))

        // Give the supervisor time to notice the crash, restart, and the watcher to pick up :9002/.
        try? await Task.sleep(nanoseconds: 700_000_000)
        let updated = await server.readyURL
        #expect(updated == URL(string: "http://localhost:9002/"))

        await server.stop(timeout: 2)
    }

    @Test func `On ready URL change fires when a restart picks a new port`() async throws {
        let supervisor = ProcessSupervisor()
        let center = LogCenter()
        let server = AstroDevServer(supervisor: supervisor, logCenter: center, readinessProbe: alwaysReady)

        let counter = NSTemporaryDirectory() + "astro-cb-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: counter) }
        let script = """
        f="$0"
        n=$(cat "$f" 2>/dev/null || echo 0); n=$((n+1)); echo "$n" > "$f"
        echo "  Local    http://localhost:910$n/"
        if [ "$n" -lt 2 ]; then sleep 0.2; exit 1; fi
        exec sleep 30
        """

        let observed = URLCollector()
        let first = try await server.start(
            siteDirectory: URL(fileURLWithPath: "/tmp"),
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", script, counter],
            source: "astro-cb",
            restartPolicy: .onCrash(maxAttempts: 3, baseBackoff: 0.05),
            readyTimeout: 5,
            onReadyURLChange: { url in await observed.add(url) }
        )
        #expect(first == URL(string: "http://localhost:9101/"))

        // Wait for the crash → restart → watcher → callback chain.
        try? await Task.sleep(nanoseconds: 700_000_000)
        let urls = await observed.urls
        #expect(urls == [URL(string: "http://localhost:9102/")!])

        await server.stop(timeout: 2)
    }

    @Test func `Start times out when readiness probe never succeeds`() async throws {
        let supervisor = ProcessSupervisor()
        let center = LogCenter()
        let probe: AstroDevServer.ReadinessProbe = { _ in false }
        let server = AstroDevServer(supervisor: supervisor, logCenter: center, readinessProbe: probe)

        await #expect(throws: AstroDevServer.AstroError.readyTimeout) {
            _ = try await server.start(
                siteDirectory: URL(fileURLWithPath: "/tmp"),
                executable: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", "echo '  Local    http://localhost:4321/'; exec sleep 30"],
                source: "astro-probe-timeout",
                readyTimeout: 0.5
            )
        }
        let isRunning = await server.isRunning
        #expect(!isRunning)
    }
}

private actor ProbeCounter {
    private(set) var value = 0
    func bump() -> Int { value += 1; return value }
}

private actor URLCollector {
    private(set) var urls: [URL] = []
    func add(_ url: URL) { urls.append(url) }
}
