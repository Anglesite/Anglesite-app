import AnglesiteCore
import CoreSpotlight

/// Thin counting seam over the indexer, so the probe can take a flat fake in tests instead of
/// standing up a full `ContentSpotlightIndexer` + backend just to vary a count. The production
/// indexer conforms below.
public protocol SpotlightIndexCounting: Sendable {
    func indexedCounts(for siteID: String) async -> ContentSpotlightIndexer.IndexedCounts
}

extension ContentSpotlightIndexer: SpotlightIndexCounting {}

/// Reports how many of a site's items are published to the Spotlight semantic index Siri reads.
/// `indexingAvailable` is injected; the default reads `CSSearchableIndex.isIndexingAvailable()`.
public struct SpotlightIndexProbe: ReadinessProbe {
    public let id = "site.spotlight"
    public let title = "Spotlight index"
    private let siteID: String
    private let counter: any SpotlightIndexCounting
    private let indexingAvailable: Bool

    public init(
        siteID: String,
        counter: any SpotlightIndexCounting,
        indexingAvailable: Bool = CSSearchableIndex.isIndexingAvailable()
    ) {
        self.siteID = siteID
        self.counter = counter
        self.indexingAvailable = indexingAvailable
    }

    public func check() async -> ReadinessFinding {
        guard indexingAvailable else {
            return ReadinessFinding(id: id, title: title, level: .warning,
                detail: "Spotlight indexing is unavailable on this Mac.",
                remediation: "Make sure Spotlight is enabled in System Settings ▸ Siri & Spotlight.")
        }
        let counts = await counter.indexedCounts(for: siteID)
        if counts.total > 0 {
            return ReadinessFinding(id: id, title: title, level: .ok,
                detail: "\(counts.total) items are indexed in Spotlight for this site.")
        }
        return ReadinessFinding(id: id, title: title, level: .warning,
            detail: "Nothing is indexed in Spotlight for this site yet.",
            remediation: "Open this site's window so its content is indexed.")
    }
}
