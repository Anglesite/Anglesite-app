import Observation
import AnglesiteIntents

@MainActor
@Observable
final class ContentIndexerStore {
    var indexer: ContentSpotlightIndexer?
}
