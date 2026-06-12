import AnglesiteCore

/// Test-only escape hatch around `@Dependency` resolution of `ContentOperationsService`, mirroring
/// `SiteOperationsOverride` (see #104/#127). `@Dependency` is gated to the AppIntents perform flow;
/// direct `intent.perform()` calls from unit tests crash without it. Tests bind this `@TaskLocal`
/// to a fake service before invoking the create intents; the intents read
/// `ContentOperationsOverride.scoped ?? self.content`, so production flows through `@Dependency`.
public enum ContentOperationsOverride {
    @TaskLocal public static var scoped: (any ContentOperationsService)?
}
