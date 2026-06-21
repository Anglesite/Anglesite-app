import AppIntents
import AnglesiteCore
import OSLog

private let log = Logger(subsystem: "dev.anglesite.app", category: "spotlight-indexer")
private let contentLog = Logger(subsystem: "dev.anglesite.app", category: "content-spotlight-indexer")

/// Public entry point that registers production dependencies with `AppDependencyManager` and
/// hooks the Spotlight indexer to `SiteStore.shared`.
///
/// Async so the call site can await handler installation before driving any `SiteStore`
/// mutations — that way a caller in an async context (e.g. #101's system MCP entry from a
/// non-UI process) gets the indexer reliably set up before they touch the store.
///
/// `contentGraph` is the single, app-lifetime `SiteContentGraph` instance the app owns and
/// passes in. We register it with `AppDependencyManager` so `@Dependency private var graph:
/// SiteContentGraph` resolves to the same instance in every `PageEntityQuery` /
/// `PostEntityQuery` / `ImageEntityQuery` instantiation by the AppIntents runtime. A.1's
/// design explicitly rules out a process-wide `SiteContentGraph.shared` — ownership stays
/// with the app, threaded through here.
///
/// The kicker `try await SiteStore.shared.load()` inside is belt-and-suspenders for the
/// SwiftUI case: `AppDelegate.applicationDidFinishLaunching` can only fire-and-forget us in a
/// `Task`, which races with the launcher view's own `task` modifier. The handler is registered
/// before the load here, so the load *will* emit even if the launcher already raced ahead and
/// missed it — emission is idempotent (the indexer dedups by id set).

/// Fallback interpreter used when the Xcode-27 / `FoundationModels` toolchain is absent (CI).
/// Always throws `.unavailable` so the intent's catch path surfaces the "needs Apple Intelligence"
/// dialog rather than a fatalError from the missing `@Dependency` factory.
private struct UnavailableEditInterpreter: EditInterpreting {
    func interpret(instruction: String, element: InterpretedElementContext) async throws -> InterpretedEdit {
        throw EditInterpretationError.unavailable("FoundationModels not available on this toolchain")
    }
}

public enum AnglesiteIntents {
    @discardableResult
    public static func bootstrap(contentGraph: SiteContentGraph) async -> ContentSpotlightIndexer {
        // Singleton-factory: the closure always returns the same pre-constructed `contentGraph`
        // instance. `AppDependencyManager.add` accepts a factory because dependencies may be
        // per-resolution, but our graph is process-wide, so we capture and re-yield.
        AppDependencyManager.shared.add { () -> SiteContentGraph in contentGraph }
        AppDependencyManager.shared.add { () -> any SiteOperationsService in
            SiteOperations(factory: LiveCommandFactory())
        }
        // Content create intents (A.5 #139) now use native in-process scaffolding (Bucket 1,
        // Slice 2). Replaces the MCP-routed ContentOperations; the Node create_page/create_post
        // tools are retired in the roadmap's cleanup slice.
        AppDependencyManager.shared.add { () -> any ContentOperationsService in
            NativeContentOperations(siteDirectory: { id in await SiteStore.shared.find(id: id)?.sourceDirectory })
        }
        AppDependencyManager.shared.add { () -> any IntegrationOperationsService in
            IntegrationOperations.live()
        }
        // `EditContentIntent` (B.5 / #149) routes natural-language edits through
        // `IntentEditBridge`, which asks `EditRouterRegistry.shared` for the live edit router of
        // the requested site. The registry is populated by `PreviewModel.open()` and cleared by
        // `PreviewModel.close()` — so an edit from Siri only resolves while the site's window
        // is open. The headless fallback is deferred (out of scope for B.5).
        let editBridge = IntentEditBridge(
            routerProvider: { siteID in await EditRouterRegistry.shared.router(for: siteID) }
        )
        AppDependencyManager.shared.add { () -> IntentEditBridge in editBridge }
        // FM-backed edit interpreter for `EditContentIntent` (B.6 / #251). Gated behind the
        // Xcode-27 compiler so `AnglesiteIntents` still builds on CI's older toolchain (#128).
        // The interpreter is app-wide (no per-site state); siteID/siteDirectory are threaded
        // through `InterpretedElementContext` by `perform()` at interpret time.
        #if compiler(>=6.4)
        let fmAssistant = FoundationModelAssistant()
        let editInterpreter: any EditInterpreting = FoundationModelEditInterpreter(assistant: fmAssistant)
        #else
        let editInterpreter: any EditInterpreting = UnavailableEditInterpreter()
        #endif
        AppDependencyManager.shared.add { () -> any EditInterpreting in editInterpreter }

        await SiteStore.shared.setChangeHandler { sites in
            do {
                let outcome = try await SpotlightIndexer.shared.reindex(sites)
                log.info("indexed=\(outcome.indexed, privacy: .public) removed=\(outcome.removed, privacy: .public)")
            } catch {
                log.error("reindex failed: \(error.localizedDescription, privacy: .public)")
            }
        }

        // Mirror the content graph (pages/posts/images) into the Spotlight semantic index the same
        // way (A.3, #144). The handler fires per-siteID after every graph mutation — load on site
        // open, upsert/remove on file-watch, unload on site close — and the indexer diffs that
        // site's current snapshot against what it last published.
        let contentIndexer = ContentSpotlightIndexer(graph: contentGraph, backend: LiveContentSpotlightBackend())
        await contentGraph.setChangeHandler { siteID in
            do {
                let outcome = try await contentIndexer.reindex(siteID: siteID)
                contentLog.info("indexed=\(outcome.indexed, privacy: .public) removed=\(outcome.removed, privacy: .public)")
            } catch {
                contentLog.error("reindex failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        do {
            try await SiteStore.shared.load()
        } catch {
            log.error("initial load failed: \(error.localizedDescription, privacy: .public)")
        }
        return contentIndexer
    }
}
