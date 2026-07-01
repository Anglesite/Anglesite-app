/// Decides whether `LocalContainerSiteRuntime` can run on this build/host. The entitlement is the
/// real gate (it's unforgeable — an un-entitled build is SIGKILL'd by `amfid` at launch, see the
/// #60 spike), so no feature flag is needed: a build without it simply reports `false` and the app
/// falls back to `LocalSiteRuntime` / `RemoteSandboxSiteRuntime`.
public enum LocalContainerSupport {
    public enum Availability: Sendable, Equatable {
        case available
        case unavailable([UnavailabilityReason])

        public var isAvailable: Bool {
            if case .available = self { true } else { false }
        }
    }

    public enum UnavailabilityReason: String, Sendable, Equatable, CaseIterable {
        case notAppleSilicon
        case unsupportedOS
        case missingVirtualizationEntitlement

        public var description: String {
            switch self {
            case .notAppleSilicon:
                "Apple Silicon is required"
            case .unsupportedOS:
                "macOS 26 or newer is required"
            case .missingVirtualizationEntitlement:
                "signed build is missing com.apple.security.virtualization"
            }
        }
    }

    public static func isAvailable(
        isAppleSilicon: Bool = hostIsAppleSilicon,
        osIsSupported: Bool = hostOSIsSupported,
        hasVirtualizationEntitlement: Bool = hostHasVirtualizationEntitlement
    ) -> Bool {
        availability(
            isAppleSilicon: isAppleSilicon,
            osIsSupported: osIsSupported,
            hasVirtualizationEntitlement: hasVirtualizationEntitlement
        ).isAvailable
    }

    public static func availability(
        isAppleSilicon: Bool = hostIsAppleSilicon,
        osIsSupported: Bool = hostOSIsSupported,
        hasVirtualizationEntitlement: Bool = hostHasVirtualizationEntitlement
    ) -> Availability {
        var reasons: [UnavailabilityReason] = []
        if !isAppleSilicon { reasons.append(.notAppleSilicon) }
        if !osIsSupported { reasons.append(.unsupportedOS) }
        if !hasVirtualizationEntitlement { reasons.append(.missingVirtualizationEntitlement) }
        return reasons.isEmpty ? .available : .unavailable(reasons)
    }

    /// True on arm64. Intel Macs report false.
    public static var hostIsAppleSilicon: Bool {
        #if arch(arm64)
        return true
        #else
        return false
        #endif
    }

    /// True on macOS 26+ (the Apple-Containerization floor; intentionally below the app's macOS 27
    /// deployment target — every host the app runs on qualifies; do not raise this check).
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
