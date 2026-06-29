import Foundation
import AnglesiteCore
import Containerization
import ContainerizationOCI
import ContainerizationExtras

/// `LocalContainerControl` over Apple Containerization (package version 0.34). Imports the bundled
/// arm64 OCI layout into an on-disk `ImageStore`, unpacks it to an ext4 rootfs, boots a Linux VM
/// (`VZVirtualMachineManager`) with NAT outbound + vsock inbound, clones the site's `Source/` repo
/// into the guest, starts `astro dev` (guest TCP 4321) + the Node MCP sidecar (guest TCP 4399) +
/// the vsock bridge, and exposes both via host-side `VsockTCPProxy` instances dialing the guest
/// over vsock. CI never compiles this file (the `AnglesiteContainer` target is app-only).
///
/// API note: the implementation is written against the real 0.34 symbols, which differ from the
/// plan's intended shapes. Notably there is no `LinuxContainer(image:networking:)` — booting needs a
/// `Kernel` + an initfs `Mount` + an unpacked rootfs `Mount`; image import is `ImageStore.load(from:)`
/// (not `importIfNeeded`); exec is two-phase (`exec` builds, `.start()` runs, `.wait()` blocks);
/// networking is a `NATInterface` (not `.nat`); and `dialVsock(port:)` already returns a `FileHandle`,
/// so it slots directly into `VsockDialer`. See `.superpowers/sdd/task-7-report.md` for the full map.
public struct ContainerizationControl: LocalContainerControl {
    /// Optional explicit OCI layout override; when nil, `start()` resolves it via `BundledImage.layoutURL()`.
    /// Kept off `init` as a non-throwing default so constructing the type can never trap (the old
    /// `BundledImage.layoutURL` default argument `fatalError`'d on a missing bundle).
    private let imageLayoutURLOverride: URL?

    // One live container + its two proxies per siteID, kept in an actor box so start/stop are safe.
    private let live = LiveContainers()

    // Guest-side ports the dev server + MCP sidecar listen on (also the vsock ports the bridge maps to).
    private static let previewPort: UInt32 = 4321
    private static let mcpPort: UInt32 = 4399

    /// Guest mountpoint for the read-only virtio-fs share of the host `Source/` repo (see `start()` step 3).
    private static let repoSharePath = "/run/anglesite-source"

    public init(imageLayoutURL: URL? = nil) {
        self.imageLayoutURLOverride = imageLayoutURL
    }

    public func start(siteID: String, sourceRepo: URL, ref: String) async throws -> LocalContainerSession {
        // 0. Resolve the writable image store + boot artifacts. Kernel/initfs are not yet vendored —
        //    BundledImage surfaces that as a typed error rather than a silent mis-boot (see its TODOs).
        let storeURL: URL
        let imageLayoutURL: URL
        let kernelURL: URL
        let initfsLayoutURL: URL
        do {
            storeURL = try BundledImage.storeURL()
            imageLayoutURL = try imageLayoutURLOverride ?? BundledImage.layoutURL()
            kernelURL = try BundledImage.kernelURL()
            initfsLayoutURL = try BundledImage.initfsLayoutURL()
        } catch {
            throw LocalContainerError.imageUnavailable("\(error)")
        }

        // The two ext4 artifacts we materialize below are tracked so teardown can delete them
        // (otherwise disk grows per start/stop). Both are site-scoped so concurrent starts don't race.
        let rootfsURL = storeURL.appendingPathComponent("rootfs-\(siteID).ext4")
        let initfsURL = storeURL.appendingPathComponent("initfs-\(siteID).ext4")

        // 1. Import the bundled OCI layouts into the on-disk ImageStore and unpack to bootable mounts.
        //    `load(from:)` is idempotent against an existing store (re-import returns the same image).
        let rootfs: Containerization.Mount
        let initfs: Containerization.Mount
        do {
            let store = try ImageStore(path: storeURL)

            // App image -> ext4 rootfs mount.
            let appImage = try await loadOrGet(store, layout: imageLayoutURL, reference: BundledImage.imageReference)
            rootfs = try await EXT4Unpacker(blockSizeInBytes: 8 * 1024 * 1024 * 1024)
                .unpack(appImage, for: .current, at: rootfsURL)

            // vminit initfs OCI layout -> ext4 init mount (the guest-agent root filesystem).
            let initImageRef = "vminit:latest"
            let initImage = InitImage(image: try await loadOrGet(store, layout: initfsLayoutURL, reference: initImageRef))
            initfs = try await initImage.initBlock(at: initfsURL, for: .linuxArm)
        } catch {
            // Unpacking may have created partial ext4 files before failing; don't leak them.
            try? FileManager.default.removeItem(at: rootfsURL)
            try? FileManager.default.removeItem(at: initfsURL)
            throw LocalContainerError.imageUnavailable("\(error)")
        }

        // 2. Boot the container: Apple-Silicon VZ-backed VM, NAT outbound, auto vsock device.
        let container: LinuxContainer
        do {
            let kernel = Kernel(path: kernelURL, platform: .linuxArm)
            let vmm = VZVirtualMachineManager(kernel: kernel, initialFilesystem: initfs)

            // Static NAT addressing: VZNATNetworkDeviceAttachment under the hood (resolved #317).
            let nat = NATInterface(
                ipv4Address: try CIDRv4("192.168.64.2/24"),
                ipv4Gateway: try IPv4Address("192.168.64.1")
            )

            container = try LinuxContainer(siteID, rootfs: rootfs, vmm: vmm) { config in
                // Keep the init process alive so the VM stays up while we exec into it.
                config.process.arguments = ["/bin/sh"]
                config.process.workingDirectory = "/"
                config.cpus = 2
                config.memoryInBytes = 2 * 1024 * 1024 * 1024
                config.interfaces = [nat]
                config.dns = DNS(nameservers: ["192.168.64.1"])
                // Host `Source/` repo shared read-only into the guest via virtio-fs so the guest can
                // `git clone` it (the macOS host path is otherwise invisible to the Linux guest).
                // `Mount.share(source:destination:)` is the host-directory virtio-fs share — confirmed
                // against `Mount.swift:83` and `ContainerTests.swift:628` (`.share(source: directory.path,
                // destination: "/mnt")`); `ro` is honoured (`ContainerTests.swift:3309`). NOT
                // `Mount.sharedMount`, which references a named *pod volume*, not a host path.
                config.mounts.append(.share(
                    source: sourceRepo.path,
                    destination: Self.repoSharePath,
                    options: ["ro"]
                ))
            }
            try await container.create()
            try await container.start()
        } catch {
            try? FileManager.default.removeItem(at: rootfsURL)
            try? FileManager.default.removeItem(at: initfsURL)
            throw LocalContainerError.bootFailed("\(error)")
        }

        // 3. Hydrate from the repo: clone the virtio-fs-shared host repo into /workspace/site, then
        //    check out ref. Cloning from the read-only share (not in place) keeps /workspace writable
        //    and preserves full git history — native, no network. Two steps because `git clone
        //    --branch` rejects "HEAD"/bare SHAs; `git checkout` accepts both.
        do {
            try await runToCompletion(container, id: "clone",
                ["git", "clone", Self.repoSharePath, "/workspace/site"])
            try await runToCompletion(container, id: "checkout",
                ["git", "-C", "/workspace/site", "checkout", ref])
        } catch {
            try? await container.stop()
            try? FileManager.default.removeItem(at: rootfsURL)
            try? FileManager.default.removeItem(at: initfsURL)
            throw LocalContainerError.cloneFailed("\(error)")
        }

        // 4. Start astro dev (guest TCP 4321), the MCP sidecar (guest TCP 4399), and the vsock bridge.
        //    These are detached: `exec` + `.start()` with no `.wait()`.
        do {
            try await runDetached(container, id: "astro", ["sh", "-lc",
                "cd /workspace/site && npm install --no-audit --no-fund && npx astro dev --port 4321 --host 127.0.0.1"])

            // MCP sidecar: baked into the image at /usr/local/lib/anglesite-mcp/ by the two-stage
            // Dockerfile (scripts/vendor-container-image.sh stages the plugin's server/ dir into the
            // build context; npm ci runs on linux/arm64 so @img/sharp-linux-arm64 is the native prebuilt).
            // The server reads config from ENV (not flags): ANGLESITE_MCP_TRANSPORT selects HTTP mode,
            // ANGLESITE_MCP_PORT sets the listen port, ANGLESITE_PROJECT_ROOT points at the cloned repo.
            // ANGLESITE_MCP_HOST is intentionally unset — it defaults to 127.0.0.1, which is correct:
            // the in-guest vsock bridge reaches the sidecar via dial("tcp","127.0.0.1:4399").
            try await runDetached(container, id: "mcp", ["sh", "-lc",
                "ANGLESITE_MCP_TRANSPORT=http ANGLESITE_MCP_PORT=4399 ANGLESITE_PROJECT_ROOT=/workspace/site node /usr/local/lib/anglesite-mcp/server/index.mjs"])

            // Guest vsock<->TCP bridge: maps guest vsock ports onto the local TCP listeners above so
            // host-side dialVsock reaches them. baked by Task 6.
            try await runDetached(container, id: "bridge",
                ["/usr/local/bin/vsock-bridge", "4321:4321", "4399:4399"])
        } catch {
            try? await container.stop()
            try? FileManager.default.removeItem(at: rootfsURL)
            try? FileManager.default.removeItem(at: initfsURL)
            throw LocalContainerError.bootFailed("guest process launch failed: \(error)")
        }

        // 5. Expose: a host-side vsock->TCP proxy per port. dialVsock(port:) -> FileHandle slots
        //    directly into VsockDialer (Phase 1's `@Sendable (UInt32) async throws -> FileHandle`).
        let dial: VsockDialer = { port in try await container.dialVsock(port: port) }
        let previewProxy = VsockTCPProxy(guestPort: Self.previewPort, dial: dial)
        let mcpProxy = VsockTCPProxy(guestPort: Self.mcpPort, dial: dial)
        let previewURL: URL
        let mcpURL: URL
        do {
            previewURL = try await previewProxy.start()
            let mcpBase = try await mcpProxy.start()
            mcpURL = mcpBase.appendingPathComponent("mcp")
        } catch {
            await previewProxy.stop()
            await mcpProxy.stop()
            try? await container.stop()
            try? FileManager.default.removeItem(at: rootfsURL)
            try? FileManager.default.removeItem(at: initfsURL)
            throw LocalContainerError.bootFailed("proxy start failed: \(error)")
        }

        // 6. Wait for `astro dev` to actually serve before returning, so the first preview load
        //    doesn't get connection-refused. Poll the preview URL through the host proxy until it
        //    answers (or time out). Cancellation-friendly: `Task.sleep` throws on cancel.
        do {
            try await waitUntilServing(previewURL)
        } catch {
            await previewProxy.stop()
            await mcpProxy.stop()
            try? await container.stop()
            try? FileManager.default.removeItem(at: rootfsURL)
            try? FileManager.default.removeItem(at: initfsURL)
            throw LocalContainerError.bootFailed("preview server did not become ready: \(error)")
        }

        await live.store(siteID: siteID, container: container,
            proxies: [previewProxy, mcpProxy], ext4Artifacts: [rootfsURL, initfsURL])
        return LocalContainerSession(previewURL: previewURL, mcpURL: mcpURL)
    }

    public func stop(siteID: String) async throws {
        await live.teardown(siteID: siteID)
    }

    /// Run `argv` inside the named container as a one-shot guest exec, forwarding `environment`
    /// and `workingDirectory`, streaming each stdout AND stderr line to `onOutput` as it arrives
    /// (many tools, incl. `wrangler`, write progress to stderr), capturing the full stdout + stderr,
    /// and returning the real guest exit code (it does NOT throw on a non-zero exit — the caller maps
    /// the code). Honors task cancellation: a cancelled deploy SIGTERMs the guest process, mirroring
    /// the host path. Mirrors `runToCompletion`'s lifecycle (`exec` -> `start` -> `wait` -> `delete`)
    /// but installs capturing/streaming `Writer`s.
    ///
    /// Env/cwd are set via the real 0.34 `LinuxProcessConfiguration` fields — `arguments`,
    /// `environmentVariables`, `workingDirectory` (`LinuxProcessConfiguration.swift:366-370`) — so
    /// there is no shell wrapping and therefore no shell-metacharacter injection surface: each
    /// `K=V` pair and each argv element is passed literally to the guest agent (no `sh -lc`, no
    /// `env` binary). NOTE: `LinuxContainer.exec` builds a FRESH config, so the image-baked env is
    /// NOT inherited — only the default `PATH` (which covers `/usr/local/bin` for `node:22`, so
    /// `node`/`npm`/`npx`/`wrangler` resolve) plus the caller's `environment` are set. Anything the
    /// deploy toolchain needs beyond PATH must be passed in `environment`.
    public func exec(
        siteID: String,
        argv: [String],
        environment: [String: String],
        workingDirectory: String,
        onOutput: @escaping @Sendable (String, LogCenter.Stream) -> Void
    ) async throws -> ContainerExecResult {
        guard let container = await live.container(for: siteID) else {
            throw LocalContainerError.bootFailed("exec: no live container for siteID '\(siteID)'")
        }

        // `onOutput` is `@escaping` (the seam declares it so): the `Writer` sinks below close over it
        // and may legitimately fire it after this function returns (e.g. a kill-triggered final line
        // on cancellation). No `withoutActuallyEscaping` — that wrapper would be UNSOUND here.
        //
        // Two line-splitters, one per stream, each tagging its lines with the stream it owns so the
        // caller can label wrangler's stderr progress correctly (and parse stdout for the URL).
        let stdoutSink = LineStreamingWriter(stream: .stdout, onLine: onOutput)
        let stderrSink = LineStreamingWriter(stream: .stderr, onLine: onOutput)

        // Unique exec id per call so build/preflight/wrangler don't collide on the same vended
        // process name. The label maps each step's argv to a distinct, readable suffix; a short
        // uniquifier guarantees distinctness even if two calls share a label (e.g. two `npx` steps).
        let label = Self.execLabel(for: argv)
        let proc = try await container.exec("\(siteID)-exec-\(label)-\(UUID().uuidString.prefix(8))") { config in
            config.arguments = argv
            // Preserve the default PATH (so argv[0] resolves) and append the caller's env as
            // literal `K=V` argv-style entries — no shell parsing, no escaping bugs, no injection.
            config.environmentVariables =
                ["PATH=\(LinuxProcessConfiguration.defaultPath)"]
                + environment.map { "\($0.key)=\($0.value)" }
            config.workingDirectory = workingDirectory
            config.stdout = stdoutSink
            config.stderr = stderrSink
        }
        try await proc.start()
        // Honor task cancellation for parity with the host deploy path (which SIGTERMs a
        // cancelled deploy): if the deploy task is cancelled mid-`wait()`, signal the guest
        // process so a hung/long `npm install` / `wrangler deploy` can actually be aborted.
        let status = try await withTaskCancellationHandler {
            try await proc.wait()
        } onCancel: {
            // Fire-and-forget SIGTERM. This may land AFTER `proc.delete()` runs below (the cancel
            // handler and the main flow race once `wait()` resumes). That's tolerated: `kill` and
            // `delete` are independent async ops on `LinuxProcess` with no shared guard —
            // `LinuxProcess.kill` (LinuxProcess.swift:307-321) just calls `agent.signalProcess` and
            // *throws* a wrapped `ContainerizationError` if the process is already gone, and our
            // `try?` swallows that throw. Best-effort by construction — we never need the kill to
            // succeed once the process has exited or been deleted.
            Task { try? await proc.kill(.term) }
        }
        try? await proc.delete()

        // `wait()` returns only after the IO streams have drained, so the sinks hold the full
        // output here. Flush any trailing partial (unterminated) line on each stream.
        stdoutSink.flush()
        stderrSink.flush()
        return ContainerExecResult(
            exitCode: status.exitCode,
            stdout: stdoutSink.text,
            stderr: stderrSink.text
        )
    }

    /// Maps a step's argv to a short, distinct, readable exec-id label. `npm run build` → `build`,
    /// `npx tsx …pre-deploy-check…` → `preflight`, `npx wrangler deploy` → `wrangler`; anything else
    /// falls back to argv[0]. Both `npx` steps would otherwise collapse to the same prefix.
    private static func execLabel(for argv: [String]) -> String {
        switch argv.first {
        case "npm": return "build"
        case "npx":
            if argv.contains("wrangler") { return "wrangler" }
            if argv.contains(where: { $0.contains("pre-deploy-check") }) { return "preflight" }
            return "npx"
        default: return argv.first ?? "cmd"
        }
    }

    // MARK: - Helpers

    /// Import an OCI layout into the store, tolerating a prior import (idempotent): if `load` fails
    /// because the reference already resolves, fall back to `get`.
    private func loadOrGet(_ store: ImageStore, layout: URL, reference: String) async throws -> Containerization.Image {
        if let existing = try? await store.get(reference: reference) {
            return existing
        }
        let loaded = try await store.load(from: layout)
        if let match = try? await store.get(reference: reference) {
            return match
        }
        // `get(reference:)` missed even after load. Only fall back to the loaded image if the layout
        // is unambiguous (exactly one image) — otherwise we'd risk silently booting the wrong one.
        guard loaded.count == 1, let only = loaded.first else {
            throw LocalContainerError.imageUnavailable(
                "OCI layout at \(layout.path) imported \(loaded.count) images; reference \(reference) not resolvable")
        }
        return only
    }

    /// Poll the preview URL through the host proxy until the guest dev server answers, or time out.
    /// Bounded and cancellation-aware: each `Task.sleep` throws `CancellationError` if the start task
    /// is cancelled, and the overall wait is capped so a never-ready server doesn't hang `start()`.
    private func waitUntilServing(
        _ url: URL,
        timeout: Duration = .seconds(90),
        interval: Duration = .milliseconds(500)
    ) async throws {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 5
        var lastError: Error?
        while ContinuousClock.now < deadline {
            try Task.checkCancellation()
            do {
                let (_, response) = try await URLSession.shared.data(for: request)
                // Any HTTP response means the listener is up and serving (even a 404 dev page).
                if response is HTTPURLResponse {
                    return
                }
            } catch {
                lastError = error
            }
            try await Task.sleep(for: interval)
        }
        throw LocalContainerError.bootFailed(
            "timed out after \(timeout) waiting for \(url.absoluteString)"
            + (lastError.map { "; last error: \($0)" } ?? ""))
    }

    /// Run a guest process to completion, throwing if it exits non-zero.
    private func runToCompletion(_ container: LinuxContainer, id: String, _ argv: [String]) async throws {
        let proc = try await container.exec(id) { config in
            config.arguments = argv
        }
        try await proc.start()
        let status = try await proc.wait()
        try? await proc.delete()
        guard status.exitCode == 0 else {
            throw LocalContainerError.cloneFailed("`\(argv.joined(separator: " "))` exited \(status.exitCode)")
        }
    }

    /// Start a guest process detached (no `wait`), e.g. a long-running dev server.
    ///
    /// We intentionally do NOT `delete()` these processes here, unlike `runToCompletion`. Teardown
    /// relies on `LinuxContainer.stop()` to reap them: `stop()` issues `agent.kill(pid: -1, SIGKILL)`
    /// and then iterates `vendedProcesses` calling `_delete()` on each before stopping the VM
    /// (`LinuxContainer.swift:803` and `:835-851`). Every `exec`'d process is registered in
    /// `vendedProcesses`, so stopping the container cleans them all up — no per-process tracking needed.
    private func runDetached(_ container: LinuxContainer, id: String, _ argv: [String]) async throws {
        let proc = try await container.exec(id) { config in
            config.arguments = argv
        }
        try await proc.start()
    }
}

/// Actor box holding the live container + proxies + on-disk ext4 artifacts keyed by siteID.
actor LiveContainers {
    private var containers: [String: LinuxContainer] = [:]
    private var proxies: [String: [VsockTCPProxy]] = [:]
    /// Per-site ext4 files (rootfs + initfs) to delete on teardown so disk doesn't grow per start/stop.
    private var ext4Artifacts: [String: [URL]] = [:]

    func container(for siteID: String) -> LinuxContainer? { containers[siteID] }

    func store(siteID: String, container: LinuxContainer, proxies ps: [VsockTCPProxy], ext4Artifacts artifacts: [URL]) {
        containers[siteID] = container
        proxies[siteID] = ps
        ext4Artifacts[siteID] = artifacts
    }

    func teardown(siteID: String) async {
        for p in proxies[siteID] ?? [] { await p.stop() }
        proxies[siteID] = nil
        // Stop the VM first (releases the file handles), then remove the backing ext4 images.
        if let c = containers[siteID] { try? await c.stop() }
        containers[siteID] = nil
        for url in ext4Artifacts[siteID] ?? [] {
            try? FileManager.default.removeItem(at: url)
        }
        ext4Artifacts[siteID] = nil
    }
}

/// A Containerization `Writer` that splits the guest stream into newline-delimited lines, forwarding
/// each completed line to `onLine` as it arrives (live streaming) while also accumulating the full
/// raw text. Bytes are buffered until a `\n` is seen so a chunk that splits mid-line doesn't emit a
/// partial line; `flush()` (called after `wait()`) emits any trailing unterminated line.
///
/// Single-handler invocation (one `FileHandle` readability handler) means no concurrent access, so
/// `@unchecked Sendable` is safe here exactly as for the upstream test `BufferWriter`.
final class LineStreamingWriter: @unchecked Sendable, Writer {
    private let stream: LogCenter.Stream
    private let onLine: @Sendable (String, LogCenter.Stream) -> Void
    private var pending = Data()   // bytes after the last emitted newline
    private var full = Data()      // entire raw stream, for `text`

    init(stream: LogCenter.Stream, onLine: @escaping @Sendable (String, LogCenter.Stream) -> Void) {
        self.stream = stream
        self.onLine = onLine
    }

    var text: String { String(decoding: full, as: UTF8.self) }

    func write(_ data: Data) throws {
        guard !data.isEmpty else { return }
        full.append(data)
        pending.append(data)
        let newline = UInt8(ascii: "\n")
        while let idx = pending.firstIndex(of: newline) {
            let lineData = pending[pending.startIndex..<idx]
            onLine(String(decoding: lineData, as: UTF8.self), stream)
            pending = Data(pending[pending.index(after: idx)...])
        }
    }

    func close() throws {}

    /// Emit any buffered bytes that were never newline-terminated as a final line.
    func flush() {
        guard !pending.isEmpty else { return }
        onLine(String(decoding: pending, as: UTF8.self), stream)
        pending.removeAll()
    }
}
