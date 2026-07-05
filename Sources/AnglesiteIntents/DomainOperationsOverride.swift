import AnglesiteCore

/// Test-only escape hatch around `@Dependency` resolution of `DomainOperationsService`,
/// mirroring `IntegrationOperationsOverride`. Tests bind this `@TaskLocal` to a fake service
/// before invoking the domain intents; the intents read `DomainOperationsOverride.scoped ?? self.ops`,
/// so production flows through `@Dependency`.
public enum DomainOperationsOverride {
    @TaskLocal public static var scoped: (any DomainOperationsService)?
}
