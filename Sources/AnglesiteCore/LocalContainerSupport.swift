import Foundation

/// Decides whether `LocalContainerSiteRuntime` can run on this build/host. The entitlement is the
/// real gate (it's unforgeable — an un-entitled build is SIGKILL'd by `amfid` at launch, see the
/// #60 spike), so no feature flag is needed: a build without it simply reports `false` and the app
/// falls back to `LocalSiteRuntime` / `RemoteSandboxSiteRuntime`.
public enum LocalContainerSupport {
    public static func isAvailable(
        isAppleSilicon: Bool = hostIsAppleSilicon,
        osIsSupported: Bool = hostOSIsSupported,
        hasVirtualizationEntitlement: Bool = hostHasVirtualizationEntitlement
    ) -> Bool {
        isAppleSilicon && osIsSupported && hasVirtualizationEntitlement
    }

    /// True on arm64. Intel Macs report false.
    public static var hostIsAppleSilicon: Bool {
        #if arch(arm64)
        return true
        #else
        return false
        #endif
    }

    /// True on macOS 26+ (the floor for Apple Containerization's vsock + NAT model).
    public static var hostOSIsSupported: Bool {
        if #available(macOS 26.0, *) { return true } else { return false }
    }

    /// Whether this process carries `com.apple.security.virtualization`. Read from the signed
    /// entitlements via `SecTaskCopyValueForEntitlement`; absent/unsigned → false. The concrete
    /// probe lives in `AnglesiteContainer` (it needs `Security`/`Virtualization` to confirm a
    /// usable VM); in `AnglesiteCore` the default is conservatively false so CI never selects the
    /// container path. Production overrides this via the `isAvailable(...)` parameter from the app.
    public static var hostHasVirtualizationEntitlement: Bool { false }
}
