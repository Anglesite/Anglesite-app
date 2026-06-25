import Foundation

/// Sentinel for `Bundle(for:)`-based resource-bundle discovery (no NSObject subclass needed elsewhere).
private final class BundleToken {}

/// Resolves the vendored boot artifacts that ship inside AnglesiteContainer's resource bundle.
///
/// The arm64 OCI app layout (`Resources/container-image/`, copied in via Package.swift, vendored by
/// `scripts/vendor-container-image.sh`) is the one artifact Task 6 actually produces. Booting a
/// `LinuxContainer` with Apple Containerization 0.34 additionally requires a **Linux kernel binary**
/// and a **vminit initfs** (the guest-agent root filesystem) — neither of which is vendored yet.
/// Those two are resolved here through env overrides with a bundled fallback so the boot path is
/// fully wired; the fallback URLs are marked as provisioning gaps (see `kernelURL` / `initfsLayoutURL`).
///
/// Settings/dev overrides (mirroring `TemplateRuntime`'s dev override) let a developer point each
/// artifact at a freshly-built copy without rebuilding the app.
public enum BundledImage {
    /// The AnglesiteContainer resource bundle.
    ///
    /// We can't use the SwiftPM-generated `Bundle.module`: under the `swiftbuild` build system
    /// (the SwiftPM default since Swift 6.x, and what CI's `swift test` uses) the generated accessor
    /// is compiled out (`SWIFT_MODULE_RESOURCE_BUNDLE_UNAVAILABLE`) and `Bundle.module` is internal +
    /// unavailable, so referencing it fails to compile. Instead we locate the conventionally-named
    /// `Anglesite_AnglesiteContainer.bundle` next to the loaded module/executable — robust across both
    /// the `native` and `swiftbuild` systems and the final `.app`. Override the whole layout with
    /// `ANGLESITE_CONTAINER_IMAGE` to skip bundle lookup entirely.
    static var resourceBundle: Bundle? {
        let bundleName = "Anglesite_AnglesiteContainer.bundle"
        var candidates: [URL] = []
        // Alongside the loader's bundle (the .app's framework dir, or the test bundle).
        let host = Bundle(for: BundleToken.self).bundleURL
        candidates.append(host.deletingLastPathComponent())
        candidates.append(host)
        // Alongside the main executable (xctest / CLI).
        candidates.append(Bundle.main.bundleURL)
        candidates.append(Bundle.main.bundleURL.deletingLastPathComponent())
        for base in candidates {
            let url = base.appendingPathComponent(bundleName)
            if let b = Bundle(url: url) { return b }
        }
        return nil
    }

    /// The on-disk OCI layout (`oci-layout` + `index.json` + `blobs/`) for the Anglesite dev image.
    /// Override with `ANGLESITE_CONTAINER_IMAGE`.
    public static var layoutURL: URL {
        if let override = ProcessInfo.processInfo.environment["ANGLESITE_CONTAINER_IMAGE"] {
            return URL(fileURLWithPath: override)
        }
        guard let url = resourceBundle?.url(forResource: "container-image", withExtension: nil) else {
            fatalError("AnglesiteContainer resource bundle is missing container-image/")
        }
        return url
    }

    /// The reference under which the imported app image is addressed in the on-disk `ImageStore`.
    /// Docker buildx normalizes bare names to `docker.io/library/<name>:<tag>` when writing
    /// `io.containerd.image.name` into the OCI layout — so this must match that canonical form
    /// so `ImageStore.get(reference:)` finds the image after `load(from:)`.
    public static let imageReference = "docker.io/library/anglesite-dev:latest"

    /// Path to the Linux kernel binary the VM boots.
    ///
    /// - TODO(#69): the kernel is NOT yet vendored into the app bundle — Task 6 only vendors the OCI
    ///   app layout. Provisioning it (vendor a kernel into `Resources/container-image-kernel` via a
    ///   `vendor-container-kernel.sh`, vs. ship Apple's `vminit` kernel, vs. fetch on first boot) is an
    ///   unresolved design decision above Task 7's scope. Until then this resolves only via the
    ///   `ANGLESITE_CONTAINER_KERNEL` override (set on an entitled dev machine for the gated e2e test);
    ///   the bundled fallback throws so the gap surfaces loudly rather than silently mis-booting.
    public static func kernelURL() throws -> URL {
        if let override = ProcessInfo.processInfo.environment["ANGLESITE_CONTAINER_KERNEL"] {
            return URL(fileURLWithPath: override)
        }
        if let url = resourceBundle?.url(forResource: "container-kernel", withExtension: nil) {
            return url
        }
        throw BundledImageError.kernelNotProvisioned
    }

    /// Path to the vminit initfs OCI layout (the guest-agent root filesystem the VM mounts first).
    ///
    /// - TODO(#69): like the kernel, the initfs is NOT yet vendored — same unresolved provisioning
    ///   decision. Resolves only via `ANGLESITE_CONTAINER_INITFS` until vendored; bundled fallback throws.
    public static func initfsLayoutURL() throws -> URL {
        if let override = ProcessInfo.processInfo.environment["ANGLESITE_CONTAINER_INITFS"] {
            return URL(fileURLWithPath: override)
        }
        if let url = resourceBundle?.url(forResource: "container-initfs", withExtension: nil) {
            return url
        }
        throw BundledImageError.initfsNotProvisioned
    }

    /// A writable directory for the on-disk `ImageStore` (content store + unpacked ext4 rootfs).
    /// `ImageStore`/`EXT4Unpacker` need a writable scratch path; the read-only app bundle can't host it.
    /// Override with `ANGLESITE_CONTAINER_STORE`; defaults under the app's Application Support.
    public static func storeURL() throws -> URL {
        if let override = ProcessInfo.processInfo.environment["ANGLESITE_CONTAINER_STORE"] {
            return URL(fileURLWithPath: override)
        }
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        )
        let dir = base.appendingPathComponent("Anglesite/container-store", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}

public enum BundledImageError: Error, Equatable {
    /// The Linux kernel binary is not vendored and no `ANGLESITE_CONTAINER_KERNEL` override was set.
    case kernelNotProvisioned
    /// The vminit initfs is not vendored and no `ANGLESITE_CONTAINER_INITFS` override was set.
    case initfsNotProvisioned
}
