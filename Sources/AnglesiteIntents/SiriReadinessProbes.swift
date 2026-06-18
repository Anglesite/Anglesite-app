// Sources/AnglesiteIntents/SiriReadinessProbes.swift
import AnglesiteCore

/// Assembles the readiness probe sets. Lives in AnglesiteIntents — the one module that can see
/// both the Core probes and the Intents probes.
public enum SiriReadinessProbes {
    /// Global capabilities, independent of any site.
    public static func system() -> [any ReadinessProbe] {
        [
            OSRuntimeProbe(),
            AppIntentsRegistrationProbe(),
            ViewAnnotationsProbe(),
            FoundationModelsProbe(availability: { LiveFoundationModelsAvailability.current() }),
            SystemMCPBridgeProbe(),
        ]
    }

    /// Per-site readiness for one open/known site.
    public static func site(
        siteID: String,
        graph: SiteContentGraph,
        indexer: ContentSpotlightIndexer
    ) -> [any ReadinessProbe] {
        [
            ContentGraphProbe(siteID: siteID, graph: graph),
            SpotlightIndexProbe(siteID: siteID, indexer: indexer),
        ]
    }
}
