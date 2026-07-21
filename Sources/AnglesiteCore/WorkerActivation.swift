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

    /// The effective active worker set as full `WorkerDescriptor`s, resolved by id against
    /// `catalog` — what `WorkerComposition.generateWranglerToml` and
    /// `SocialWorkerProvisionCommand.provision` need now that composition is descriptor-driven
    /// (#708). An id present in `activeIDs` but absent from `catalog` (a stale id, or a catalog
    /// fetch that hasn't happened yet) is silently dropped — there is no descriptor data to
    /// compose it with. Mirrors `WorkerRouteClaims.activeClaims(catalog:activeIDs:)`'s shape.
    public static func activeDescriptors(catalog: [WorkerDescriptor], activeIDs: Set<String>) -> [WorkerDescriptor] {
        catalog.sorted(by: { $0.id < $1.id }).filter { activeIDs.contains($0.id) }
    }

    /// Active ids `activeDescriptors` couldn't resolve against the catalog — a fully-empty
    /// catalog (no fetch has ever succeeded) is the common case, but a *partial* catalog missing
    /// just one active id (a stale id, or an entry a newer `catalog.json` removed) hits this too.
    /// Both deploy paths (`DeployModel.runDeploy`, `SiteOperations.deployWithWorkerComposition`)
    /// check this — not just `catalog.isEmpty` — so a partial mismatch isn't silent either.
    public static func unresolvedActiveIDs(activeIDs: Set<String>, resolved: [WorkerDescriptor]) -> Set<String> {
        activeIDs.subtracting(Set(resolved.map(\.id)))
    }

    /// The shared debug-pane warning text for `unresolvedActiveIDs`, so the wording can't drift
    /// between `DeployModel.swift` and `SiteOperations.swift` the way it already had once (#708
    /// review feedback). `nil` when there's nothing to warn about.
    public static func missingDescriptorWarning(unresolvedIDs: Set<String>) -> String? {
        guard !unresolvedIDs.isEmpty else { return nil }
        return "no catalog entry for active worker(s) \(unresolvedIDs.sorted().joined(separator: ", ")) — deploying with no resource bindings or route claims for them; wrangler.toml composition will be incomplete until a catalog fetch resolves them"
    }
}
