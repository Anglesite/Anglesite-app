/// Test-only escape hatch around `@Dependency`-resolved `IntentEditBridge`.
///
/// `@Dependency` is gated by the AppIntents runtime; direct unit-test invocations crash through
/// `AppDependencyManager`. Tests bind this `@TaskLocal` to a bridge configured with a stub
/// `RouterProvider` before invoking an intent's `perform()`; the intent reads
/// `IntentEditBridgeOverride.scoped ?? bridge` so the override wins when set.
///
/// `internal`-flavored access via the same pattern as `ContentGraphOverride`,
/// `ContentOperationsOverride`, and `ElementEntityProviderOverride` — `public` so the
/// `AnglesiteIntents` module's tests can bind it via `@testable import`. Production never sets it.
public enum IntentEditBridgeOverride {
    @TaskLocal public static var scoped: IntentEditBridge?
}
