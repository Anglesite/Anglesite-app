import AppIntents
import AnglesiteCore

/// Public entry point that registers production dependencies with `AppDependencyManager` and
/// hooks the Spotlight indexer to `SiteStore.shared`.
///
/// Called once from `AppDelegate.applicationDidFinishLaunching` today. #101 (system MCP)
/// will reuse this from a non-UI process so a backgrounded intent can resolve `SiteOperationsService`
/// before any window is opened.
public enum AnglesiteIntents {
    public static func bootstrap() {
        AppDependencyManager.shared.add { () -> any SiteOperationsService in
            SiteOperations(factory: LiveCommandFactory())
        }

        // Wire the Spotlight indexer to the shared SiteStore. From now on, every load /
        // refresh / add / remove fires the handler, which reindexes the semantic index — so
        // Siri can resolve "back up my portfolio" against current registry state without us
        // having to call into the indexer at every mutation site.
        Task {
            await SiteStore.shared.setChangeHandler { sites in
                do {
                    try await SpotlightIndexer.shared.reindex(sites)
                } catch {
                    // Index failures are non-fatal — the app still works, the user just doesn't
                    // get Spotlight discoverability for that snapshot. Logged via os_log; we
                    // don't surface UI for it.
                }
            }
        }
    }
}
