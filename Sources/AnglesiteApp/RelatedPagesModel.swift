// Sources/AnglesiteApp/RelatedPagesModel.swift
import Foundation
import Observation
import AnglesiteCore

@MainActor
@Observable
final class RelatedPagesModel {
    private(set) var suggestions: [LinkGraph.LinkSuggestion] = []
    private(set) var orphanHints: [SiteKnowledgeIndex.Document] = []
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
        let docID = SiteKnowledgeIndex.documentID(siteID: siteID, relativePath: path)

        // Semantic suggestions
        let related: [SemanticRanker.Ranked]
        if let ranker {
            related = await ranker.related(siteID: siteID, toDocID: docID, limit: 20)
        } else {
            related = []
        }

        let allSuggestions = LinkGraph.suggestLinks(
            forDocumentAt: path, in: documents, rankedRelated: related, limit: 12)

        suggestions = allSuggestions.filter { !ignored.contains($0.path) }

        // Link-graph hints scoped to the current page
        let analysis = LinkGraph.analyze(documents: documents)
        orphanHints = analysis.orphanPages.filter { $0.path == path }
        reciprocalHints = analysis.reciprocalGaps.filter { $0.sourcePath == path }
    }

    func ignore(_ suggestion: LinkGraph.LinkSuggestion) {
        ignored.insert(suggestion.path)
        suggestions.removeAll { $0.path == suggestion.path }
    }

    func clear() {
        currentPath = nil
        suggestions = []
        orphanHints = []
        reciprocalHints = []
    }
}
