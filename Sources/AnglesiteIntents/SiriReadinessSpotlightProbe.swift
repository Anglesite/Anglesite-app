import AnglesiteCore
import CoreSpotlight

/// Reports how many of a site's items are published to the Spotlight semantic index Siri reads.
/// `indexingAvailable` is injected; the default reads `CSSearchableIndex.isIndexingAvailable()`.
public struct SpotlightIndexProbe: ReadinessProbe {
    public let id = "site.spotlight"
    public let title = "Spotlight index"
    private let siteID: String
    private let indexer: ContentSpotlightIndexer
    private let indexingAvailable: Bool

    public init(
        siteID: String,
        indexer: ContentSpotlightIndexer,
        indexingAvailable: Bool = CSSearchableIndex.isIndexingAvailable()
    ) {
        self.siteID = siteID
        self.indexer = indexer
        self.indexingAvailable = indexingAvailable
    }

    public func check() async -> ReadinessFinding {
        guard indexingAvailable else {
            return ReadinessFinding(id: id, title: title, level: .warning,
                detail: "Spotlight indexing is unavailable on this Mac.",
                remediation: "Make sure Spotlight is enabled in System Settings ▸ Siri & Spotlight.")
        }
        let counts = await indexer.indexedCounts(for: siteID)
        if counts.total > 0 {
            return ReadinessFinding(id: id, title: title, level: .ok,
                detail: "\(counts.total) items are indexed in Spotlight for this site.")
        }
        return ReadinessFinding(id: id, title: title, level: .warning,
            detail: "Nothing is indexed in Spotlight for this site yet.",
            remediation: "Open this site's window so its content is indexed.")
    }
}
