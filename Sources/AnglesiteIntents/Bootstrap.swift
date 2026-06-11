import AppIntents
import AnglesiteCore

/// Public entry point that registers production dependencies with `AppDependencyManager`.
///
/// Called once from `AppDelegate.applicationDidFinishLaunching` today. #101 (system MCP)
/// will reuse this from a non-UI process so a backgrounded intent can resolve `SiteOperationsService`
/// before any window is opened.
public enum AnglesiteIntents {
    public static func bootstrap() {
        AppDependencyManager.shared.add { () -> any SiteOperationsService in
            SiteOperations(factory: LiveCommandFactory())
        }
    }
}
