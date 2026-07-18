import Foundation

/// Computes which `@dwk/workers` catalog workers are active for a site right now, and diffs
/// that against the last-deployed set. Pure — no I/O, no actor isolation — so every input
/// (settings, catalog, graph snapshot) must be gathered by the caller first (#709 design §4).
public enum WorkerActivation {
    /// The effective active worker-id set: component-tied workers with at least one
    /// `ImpactAnalysis`-affected page, unioned with settings-activated workers the user toggled
    /// on. `graph` is `nil` for a headless deploy with no populated `SiteContentGraph` — in that
    /// case component-tied workers contribute nothing (`ImpactAnalysis` "never invents, may
    /// under-report" bias), while `activeWorkerIDs` still applies. If `catalog` is empty (no
    /// successful fetch, no cache — `WorkerCatalogFetcher` already degrades to cache on failure,
    /// so this is a fresh-install-with-no-network edge case), `activeWorkerIDs` is trusted
    /// verbatim instead of being intersected away, so a transient fetch failure can't silently
    /// deactivate every settings-activated worker.
    public static func effectiveActiveIDs(
        settings: SiteSettings,
        catalog: [WorkerDescriptor],
        graph: SiteGraphExplorerSnapshot?
    ) -> Set<String> {
        var active: Set<String> = []

        if let graph {
            for descriptor in catalog {
                guard case .componentTied(let componentIDs) = descriptor.binding else { continue }
                let isUsed = componentIDs.contains { componentID in
                    guard let report = ImpactAnalysis.analyze(snapshot: graph, targetID: componentID) else {
                        return false
                    }
                    return !report.affectedPages.isEmpty
                }
                if isUsed { active.insert(descriptor.id) }
            }
        }

        let requested = Set(settings.activeWorkerIDs ?? [])
        if catalog.isEmpty {
            active.formUnion(requested)
        } else {
            let settingsActivatedIDs = Set(catalog.compactMap { descriptor -> String? in
                guard case .settingsActivated = descriptor.binding else { return nil }
                return descriptor.id
            })
            active.formUnion(requested.intersection(settingsActivatedIDs))
        }

        return active
    }

    /// Worker ids present in `previous` but absent from `next` — used only to log what a deploy
    /// is tearing down (#709 design §7); the removal itself happens by omission from the newly
    /// generated `wrangler.toml`, not a separate API call.
    public static func removedIDs(previous: Set<String>, next: Set<String>) -> Set<String> {
        previous.subtracting(next)
    }

    /// Interim catalog-id → `Feature` shim (#709 design §4/§10): `generateWranglerToml` and
    /// `SocialWorkerProvisionCommand.provision` still take `[WorkerComposition.Feature]`, not
    /// `[WorkerDescriptor]`, until #708 migrates them. An id with no matching `Feature` case (a
    /// future, not-yet-composed catalog worker) is silently dropped — there is nothing else this
    /// call can do with it today. Iterating `Feature.allCases` (rather than mapping `ids`
    /// directly) gives deterministic, declaration-order output for stable `wrangler.toml` diffs.
    public static func mapToFeatures(_ ids: Set<String>) -> [WorkerComposition.Feature] {
        WorkerComposition.Feature.allCases.filter { ids.contains($0.rawValue) }
    }
}
