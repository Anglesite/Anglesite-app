import AnglesiteCore

/// Test-only escape hatch around `@Dependency` resolution of `IntegrationOperationsService`,
/// mirroring `ContentOperationsOverride`. `@Dependency` is gated to the AppIntents perform
/// flow; direct calls from unit tests would otherwise crash. Tests bind this `@TaskLocal` to
/// a fake service before invoking the integration intents; the intents read
/// `IntegrationOperationsOverride.scoped ?? self.ops`, so production flows through `@Dependency`.
public enum IntegrationOperationsOverride {
    @TaskLocal public static var scoped: (any IntegrationOperationsService)?
}
