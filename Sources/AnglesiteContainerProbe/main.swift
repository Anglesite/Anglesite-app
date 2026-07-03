import Foundation
import AnglesiteCore
import AnglesiteContainer
import Containerization

// `anglesite-container-probe` — a standalone, entitled CLI for exercising
// `ContainerizationControl`'s live vsock/boot path outside `swift test`.
//
// swiftpm-testing-helper (the process `swift test` actually runs) cannot carry
// `com.apple.security.virtualization` — Apple's toolchain is not ours to re-sign — so a bare
// `swift test` can never reach VM creation for `AnglesiteContainerLocalTests`'s live cases: it
// fails before `dialVsock` is ever called. This probe links `AnglesiteContainer` directly into
// its own executable, which `scripts/run-container-probe.sh` code-signs with
// `Resources/container-probe.entitlements` after building, so the *actual* running process
// carries the entitlement `swift test` cannot grant.
//
// Subcommands:
//   echo  — mirrors VsockEchoEndToEndTests: bare container, guest socat vsock-echo listener,
//           host dialVsock round-trip. THE decision gate for Task 4b.
//   boot  — mirrors ContainerizationControlTests.bootsAndServes: full start() against a
//           throwaway Astro repo, polling the preview URL for a live HTTP response. Task 5's gate.

@main
struct AnglesiteContainerProbe {
    static func main() async {
        let args = CommandLine.arguments.dropFirst()
        guard let subcommand = args.first else {
            FileHandle.standardError.write(Data("usage: anglesite-container-probe <echo|boot>\n".utf8))
            exit(2)
        }

        let exitCode: Int32
        switch subcommand {
        case "echo":
            exitCode = await runEcho()
        case "boot":
            exitCode = await runBoot()
        default:
            FileHandle.standardError.write(Data("unknown subcommand '\(subcommand)' (expected echo|boot)\n".utf8))
            exitCode = 2
        }
        exit(exitCode)
    }

    /// Logs every guest-process output line to stderr, tagged with its stream — the same
    /// diagnostic trail `LocalContainerSiteRuntime`/the test suite capture via `onOutput`. A
    /// `@Sendable` closure constant (rather than a plain static method reference) so it converts
    /// cleanly to the `@Sendable (String, LogCenter.Stream) -> Void` the seam expects.
    private static let logLine: @Sendable (String, LogCenter.Stream) -> Void = { line, stream in
        FileHandle.standardError.write(Data("[\(stream)] \(line)\n".utf8))
    }

    // MARK: - echo

    /// Mirrors `VsockEchoEndToEndTests.vsockEchoRoundTrip`: boot a bare container (no repo
    /// mount), start a guest socat vsock-echo listener on :9999, dial it from the host, and
    /// confirm a round-tripped payload. THE live decision gate — see the task brief.
    private static func runEcho() async -> Int32 {
        let siteID = "vsock-echo-probe"
        let control = ContainerizationControl()

        let container: LinuxContainer
        do {
            container = try await control.makeBareContainer(siteID: siteID)
        } catch {
            print("GATE: FAIL — makeBareContainer threw: \(error)")
            return 1
        }

        // ALWAYS stopBareContainer on every exit path below — the defer-equivalent the brief
        // calls for. `defer` bodies can't `await`, so every early return funnels through this
        // instead of a literal `defer`.
        func fail(_ message: String) async -> Int32 {
            print(message)
            await control.stopBareContainer(container, siteID: siteID)
            return 1
        }

        do {
            try await control.runDetached(
                container, id: "echo", label: "echo", onOutput: logLine,
                ["/usr/bin/socat", "VSOCK-LISTEN:9999,reuseaddr,fork", "EXEC:cat"])
        } catch {
            return await fail("GATE: FAIL — failed to launch guest socat echo listener: \(error)")
        }

        // Retry the dial until the listener is up (socat needs a beat to bind) — up to ~10s.
        var handle: FileHandle?
        var lastDialError: Error?
        for _ in 0..<40 {
            do {
                handle = try await container.dialVsock(port: 9999)
                break
            } catch {
                lastDialError = error
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
        guard let fh = handle else {
            return await fail("GATE: FAIL — never dialed guest vsock :9999 within 10s; last error: "
                + "\(String(describing: lastDialError))")
        }

        let payload = Data("ping-vsock-echo\n".utf8)
        do {
            try fh.write(contentsOf: payload)
        } catch {
            return await fail("GATE: FAIL — write to vsock handle failed: \(error)")
        }

        // Read until the payload echoes back (or a 10s deadline) — the historical #69 signature
        // to watch for is dial-ok followed by an instant EOF/EPIPE (empty `availableData` forever).
        var received = Data()
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while received.count < payload.count, ContinuousClock.now < deadline {
            let chunk = fh.availableData
            if chunk.isEmpty {
                try? await Task.sleep(for: .milliseconds(100))
            } else {
                received.append(chunk)
            }
        }
        try? fh.close()

        guard received == payload else {
            return await fail("GATE: FAIL — echo mismatch: got \(received.count)/\(payload.count) bytes "
                + "(\(received as NSData)) — dial-ok/instant-EOF signature means the vsock data "
                + "path is broken at the framework layer")
        }

        print("GATE: PASS")
        await control.stopBareContainer(container, siteID: siteID)
        return 0
    }

    // MARK: - boot

    /// Mirrors `ContainerizationControlTests.bootsAndServes`: full `start()` against a throwaway
    /// Astro repo (git init + one commit), bounded poll of the returned preview URL for a live
    /// HTTP response, reporting boot wall-clock. Task 5's gate — compile-checked here, not run
    /// as part of Task 4b (per the task brief).
    private static func runBoot() async -> Int32 {
        let siteID = "container-boot-probe"
        let control = ContainerizationControl()

        let repo: URL
        do {
            repo = try makeThrowawayAstroRepo()
        } catch {
            print("BOOT: FAIL — could not create throwaway Astro repo: \(error)")
            return 1
        }
        defer { try? FileManager.default.removeItem(at: repo) }

        let clock = ContinuousClock()
        let start = clock.now
        let session: LocalContainerSession
        do {
            session = try await control.start(siteID: siteID, sourceRepo: repo, ref: "HEAD", onOutput: logLine)
        } catch {
            print("BOOT: FAIL — control.start threw: \(error)")
            return 1
        }

        let ok = await pollForHTTPResponse(session.previewURL, timeout: .seconds(120))
        let elapsed = clock.now - start
        try? await control.stop(siteID: siteID)

        guard ok else {
            print("BOOT: FAIL — preview URL never answered within the timeout (elapsed \(elapsed))")
            return 1
        }

        print("BOOT: PASS (boot wall-clock: \(elapsed))")
        return 0
    }

    /// Polls `url` for any HTTP response (any status code is a pass — we only care that the
    /// guest dev server is accepting connections and speaking HTTP), bounded by `timeout`.
    private static func pollForHTTPResponse(_ url: URL, timeout: Duration) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            do {
                let (_, response) = try await URLSession.shared.data(from: url)
                if response is HTTPURLResponse { return true }
            } catch {
                // Not ready yet — the guest may still be installing deps / starting astro.
            }
            try? await Task.sleep(for: .milliseconds(500))
        }
        return false
    }

    /// Create a throwaway on-disk git repo containing a minimal Astro site and an initial
    /// commit. Mirrors `ContainerizationControlTests.makeThrowawayAstroRepo` — kept as a small,
    /// self-contained helper here rather than sharing code across the test target/executable
    /// boundary (SwiftPM test targets aren't importable from an executable target).
    private static func makeThrowawayAstroRepo() throws -> URL {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("anglesite-probe-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)

        try """
        {
          "name": "anglesite-probe",
          "private": true,
          "dependencies": { "astro": "*" }
        }
        """.write(to: dir.appendingPathComponent("package.json"), atomically: true, encoding: .utf8)

        let pages = dir.appendingPathComponent("src/pages", isDirectory: true)
        try fm.createDirectory(at: pages, withIntermediateDirectories: true)
        try "<html><body><h1>Anglesite probe</h1></body></html>\n"
            .write(to: pages.appendingPathComponent("index.astro"), atomically: true, encoding: .utf8)

        func git(_ args: [String]) throws {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            p.arguments = args
            p.currentDirectoryURL = dir
            p.environment = ProcessInfo.processInfo.environment
                .merging(["GIT_AUTHOR_NAME": "probe", "GIT_AUTHOR_EMAIL": "probe@anglesite.test",
                          "GIT_COMMITTER_NAME": "probe", "GIT_COMMITTER_EMAIL": "probe@anglesite.test"]) { _, new in new }
            try p.run()
            p.waitUntilExit()
            guard p.terminationStatus == 0 else {
                throw LocalContainerError.cloneFailed("git \(args.joined(separator: " ")) exited \(p.terminationStatus)")
            }
        }
        try git(["init", "-q"])
        try git(["add", "-A"])
        try git(["commit", "-q", "-m", "initial"])
        return dir
    }
}
