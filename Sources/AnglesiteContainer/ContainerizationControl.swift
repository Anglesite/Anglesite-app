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
    private let imageLayoutURL: URL

    // One live container + its two proxies per siteID, kept in an actor box so start/stop are safe.
    private let live = LiveContainers()

    // Guest-side ports the dev server + MCP sidecar listen on (also the vsock ports the bridge maps to).
    private static let previewPort: UInt32 = 4321
    private static let mcpPort: UInt32 = 4399

    public init(imageLayoutURL: URL = BundledImage.layoutURL) {
        self.imageLayoutURL = imageLayoutURL
    }

    public func start(siteID: String, sourceRepo: URL, ref: String) async throws -> LocalContainerSession {
        // 0. Resolve the writable image store + boot artifacts. Kernel/initfs are not yet vendored —
        //    BundledImage surfaces that as a typed error rather than a silent mis-boot (see its TODOs).
        let storeURL: URL
        let kernelURL: URL
        let initfsLayoutURL: URL
        do {
            storeURL = try BundledImage.storeURL()
            kernelURL = try BundledImage.kernelURL()
            initfsLayoutURL = try BundledImage.initfsLayoutURL()
        } catch {
            throw LocalContainerError.imageUnavailable("\(error)")
        }

        // 1. Import the bundled OCI layouts into the on-disk ImageStore and unpack to bootable mounts.
        //    `load(from:)` is idempotent against an existing store (re-import returns the same image).
        let rootfs: Containerization.Mount
        let initfs: Containerization.Mount
        do {
            let store = try ImageStore(path: storeURL)

            // App image -> ext4 rootfs mount.
            let appImage = try await loadOrGet(store, layout: imageLayoutURL, reference: BundledImage.imageReference)
            let rootfsURL = storeURL.appendingPathComponent("rootfs-\(siteID).ext4")
            rootfs = try await EXT4Unpacker(blockSizeInBytes: 8 * 1024 * 1024 * 1024)
                .unpack(appImage, for: .current, at: rootfsURL)

            // vminit initfs OCI layout -> ext4 init mount (the guest-agent root filesystem).
            let initImageRef = "vminit:latest"
            let initImage = InitImage(image: try await loadOrGet(store, layout: initfsLayoutURL, reference: initImageRef))
            let initfsURL = storeURL.appendingPathComponent("initfs.ext4")
            initfs = try await initImage.initBlock(at: initfsURL, for: .linuxArm)
        } catch {
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
            }
            try await container.create()
            try await container.start()
        } catch {
            throw LocalContainerError.bootFailed("\(error)")
        }

        // 3. Hydrate from the repo: clone the host file:// repo into /workspace/site, then check out ref.
        //    Two steps because `git clone --branch` rejects "HEAD"/bare SHAs; `git checkout` accepts both.
        do {
            try await runToCompletion(container, id: "clone",
                ["git", "clone", sourceRepo.path, "/workspace/site"])
            try await runToCompletion(container, id: "checkout",
                ["git", "-C", "/workspace/site", "checkout", ref])
        } catch {
            try? await container.stop()
            throw LocalContainerError.cloneFailed("\(error)")
        }

        // 4. Start astro dev (guest TCP 4321), the MCP sidecar (guest TCP 4399), and the vsock bridge.
        //    These are detached: `exec` + `.start()` with no `.wait()`.
        do {
            try await runDetached(container, id: "astro", ["sh", "-lc",
                "cd /workspace/site && npm install --no-audit --no-fund && npx astro dev --port 4321 --host 127.0.0.1"])

            // TODO(#69): MCP sidecar not yet provisioned into the image — see plan §sidecar gap
            // (mount from app bundle's Resources/plugin/ vs. two-stage image build vs. guest fetch).
            // Task 6's image bakes Node + git + the vsock bridge only; /usr/local/lib/anglesite-mcp/
            // does NOT exist, so this launch will fail at runtime until the sidecar is provisioned.
            // Kept in the code path (and the 4399 proxy below) so the contract is complete and the
            // gap is a single, clearly-marked provisioning task rather than a structural change.
            try await runDetached(container, id: "mcp", ["sh", "-lc",
                "node /usr/local/lib/anglesite-mcp/index.mjs --port 4399"])

            // Guest vsock<->TCP bridge: maps guest vsock ports onto the local TCP listeners above so
            // host-side dialVsock reaches them. baked by Task 6.
            try await runDetached(container, id: "bridge",
                ["/usr/local/bin/vsock-bridge", "4321:4321", "4399:4399"])
        } catch {
            try? await container.stop()
            throw LocalContainerError.bootFailed("guest process launch failed: \(error)")
        }

        // 5. Expose: a host-side vsock->TCP proxy per port. dialVsock(port:) -> FileHandle slots
        //    directly into VsockDialer (Phase 1's `@Sendable (UInt32) async throws -> FileHandle`).
        let dial: VsockDialer = { port in try await container.dialVsock(port: port) }
        let previewProxy = VsockTCPProxy(guestPort: Self.previewPort, dial: dial)
        let mcpProxy = VsockTCPProxy(guestPort: Self.mcpPort, dial: dial)
        do {
            let previewURL = try await previewProxy.start()
            let mcpBase = try await mcpProxy.start()
            let mcpURL = mcpBase.appendingPathComponent("mcp")
            await live.store(siteID: siteID, container: container, proxies: [previewProxy, mcpProxy])
            return LocalContainerSession(previewURL: previewURL, mcpURL: mcpURL)
        } catch {
            await previewProxy.stop()
            await mcpProxy.stop()
            try? await container.stop()
            throw LocalContainerError.bootFailed("proxy start failed: \(error)")
        }
    }

    public func stop(siteID: String) async throws {
        await live.teardown(siteID: siteID)
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
        guard let first = loaded.first else {
            throw LocalContainerError.imageUnavailable("OCI layout at \(layout.path) imported no images")
        }
        return first
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
    private func runDetached(_ container: LinuxContainer, id: String, _ argv: [String]) async throws {
        let proc = try await container.exec(id) { config in
            config.arguments = argv
        }
        try await proc.start()
    }
}

/// Actor box holding the live container + proxies keyed by siteID.
actor LiveContainers {
    private var containers: [String: LinuxContainer] = [:]
    private var proxies: [String: [VsockTCPProxy]] = [:]

    func store(siteID: String, container: LinuxContainer, proxies ps: [VsockTCPProxy]) {
        containers[siteID] = container
        proxies[siteID] = ps
    }

    func teardown(siteID: String) async {
        for p in proxies[siteID] ?? [] { await p.stop() }
        proxies[siteID] = nil
        if let c = containers[siteID] { try? await c.stop() }
        containers[siteID] = nil
    }
}
