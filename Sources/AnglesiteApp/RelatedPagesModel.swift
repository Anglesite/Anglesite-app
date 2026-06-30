// Sources/AnglesiteApp/RelatedPagesModel.swift
import Foundation
import Observation
import AnglesiteCore

@MainActor
@Observable
final class RelatedPagesModel {
    private(set) var suggestions: [LinkGraph.LinkSuggestion] = []
    private(set) var isOrphan = false
    private(set) var reciprocalHints: [LinkGraph.ReciprocalGap] = []
    private(set) var isLoading = false

    /// Paths the user dismissed this session (not persisted in v0).
    private var ignored = Set<String>()

    private let index: SiteKnowledgeIndex
    private let ranker: SemanticRanker?

    init(index: SiteKnowledgeIndex, ranker: SemanticRanker?) {
        self.index = index
        self.ranker = ranker
    }

    /// The document path currently displayed, or `nil` when no page is loaded.
    private(set) var currentPath: String?

    func load(siteID: String, path: String) async {
        currentPath = path
        isLoading = true
        defer { isLoading = false }

        let documents = await index.documents(siteID: siteID)
        guard currentPath == path else { return }

        let docID = SiteKnowledgeIndex.documentID(siteID: siteID, relativePath: path)

        // Semantic suggestions
        let related: [SemanticRanker.Ranked]
        if let ranker {
            related = await ranker.related(siteID: siteID, toDocID: docID, limit: 20)
        } else {
            related = []
        }
        guard currentPath == path else { return }

        let allSuggestions = LinkGraph.suggestLinks(
            forDocumentAt: path, in: documents, rankedRelated: related, limit: 12)

        suggestions = allSuggestions.filter { !ignored.contains($0.path) }

        // Hop off main actor for graph analysis
        let docs = documents
        let analysis = await Task.detached(priority: .utility) {
            LinkGraph.analyze(documents: docs)
        }.value
        guard currentPath == path else { return }

        isOrphan = analysis.orphanPages.contains { $0.path == path }
        reciprocalHints = analysis.reciprocalGaps.filter { $0.sourcePath == path }
    }

    func ignore(_ suggestion: LinkGraph.LinkSuggestion) {
        ignored.insert(suggestion.path)
        suggestions.removeAll { $0.path == suggestion.path }
    }

    func clear() {
        currentPath = nil
        suggestions = []
        isOrphan = false
        reciprocalHints = []
    }
}
