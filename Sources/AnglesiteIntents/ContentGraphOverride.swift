import AnglesiteCore

/// Test-only escape hatch around `@Dependency` resolution of `SiteContentGraph`.
///
/// `@Dependency` is gated by the AppIntents runtime to its "intent perform flow" and to the
/// query-resolution flow it drives. Direct unit-test invocations (where there's no `intentsd`
/// / registered-app context) crash with a fatal error from `AppDependencyManager`. Tests bind
/// this `@TaskLocal` to a throwaway graph before invoking a query method; queries read
/// `ContentGraphOverride.scoped ?? graph` so the override takes precedence when set. In
/// production the override is always `nil` and resolution flows through `@Dependency` as designed.
///
/// Mirrors `SiteOperationsOverride.scoped` (see #104, #127).
public enum ContentGraphOverride {
    @TaskLocal public static var scoped: SiteContentGraph?
}
