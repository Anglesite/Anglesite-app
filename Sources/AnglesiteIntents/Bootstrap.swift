import AppIntents
import AnglesiteCore
import OSLog

private let log = Logger(subsystem: "dev.anglesite.app", category: "spotlight-indexer")

/// Public entry point that registers production dependencies with `AppDependencyManager` and
/// hooks the Spotlight indexer to `SiteStore.shared`.
///
/// Async so the call site can await handler installation before driving any `SiteStore`
/// mutations — that way a caller in an async context (e.g. #101's system MCP entry from a
/// non-UI process) gets the indexer reliably set up before they touch the store.
///
/// The kicker `try await SiteStore.shared.load()` inside is belt-and-suspenders for the
/// SwiftUI case: `AppDelegate.applicationDidFinishLaunching` can only fire-and-forget us in a
/// `Task`, which races with the launcher view's own `task` modifier. The handler is registered
/// before the load here, so the load *will* emit even if the launcher already raced ahead and
/// missed it — emission is idempotent (the indexer dedups by id set).
public enum AnglesiteIntents {
    public static func bootstrap() async {
        AppDependencyManager.shared.add { () -> any SiteOperationsService in
            SiteOperations(factory: LiveCommandFactory())
        }

        await SiteStore.shared.setChangeHandler { sites in
            do {
                let outcome = try await SpotlightIndexer.shared.reindex(sites)
                log.info("indexed=\(outcome.indexed, privacy: .public) removed=\(outcome.removed, privacy: .public)")
            } catch {
                log.error("reindex failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        do {
            try await SiteStore.shared.load()
        } catch {
            log.error("initial load failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
