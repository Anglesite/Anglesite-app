import Foundation

#if compiler(>=6.4)
import FoundationModels

/// FoundationModels tool for retrieving ranked excerpts from the current site's local knowledge
/// index. Complements ``SearchContentTool``: content graph search finds known pages/posts by
/// metadata, while this searches file contents across pages, components, layouts, config, and copy.
public struct SearchKnowledgeTool: Tool, Sendable {
    public static let toolName = "searchKnowledge"
    public let name = SearchKnowledgeTool.toolName
    public let description = "Search the current Astro project for relevant files and excerpts before answering or editing."

    @Generable
    public struct Arguments {
        @Guide(description: "Natural-language query or keywords to search for in the current project.")
        public var query: String
    }

    private let index: SiteKnowledgeIndex
    private let siteID: String
    private let ranker: SemanticRanker?

    public init(index: SiteKnowledgeIndex, siteID: String, ranker: SemanticRanker? = nil) {
        self.index = index
        self.siteID = siteID
        self.ranker = ranker
    }

    public func call(arguments: Arguments) async throws -> String {
        let query = arguments.query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            return "Provide a project search query."
        }
        var results = await index.search(siteID: siteID, query: query, options: .init(limit: 6))
        if let ranker {
            // Blend the lexical scores with on-device semantic similarity so retrieval matches
            // meaning, not just keywords. Falls back to pure lexical order when the ranker has
            // no vectors (no model / not yet synced).
            let semantic = await ranker.search(siteID: siteID, queryText: query, limit: 50)
            if !semantic.isEmpty {
                let lexicalScores = Dictionary(results.map { ($0.document.id, $0.score) }, uniquingKeysWith: max)
                let semanticScores = Dictionary(semantic.map { ($0.docID, Double($0.score)) }, uniquingKeysWith: max)
                let blended = SemanticRanker.blend(lexical: lexicalScores, semantic: semanticScores, semanticWeight: 0.6)
                results = results.sorted {
                    let lhs = blended[$0.document.id] ?? 0, rhs = blended[$1.document.id] ?? 0
                    return lhs != rhs ? lhs > rhs : $0.document.path < $1.document.path
                }
            }
        }
        guard !results.isEmpty else { return "No matching project context." }

        return results.map { result in
            let lineLabel: String
            if let range = result.lineRange {
                lineLabel = ":\(range.lowerBound)"
            } else {
                lineLabel = ""
            }
            let title = result.document.title.map { " - \($0)" } ?? ""
            return """
            \(result.document.kind.rawValue.uppercased())  \(result.document.path)\(lineLabel)\(title)
            \(result.excerpt)
            """
        }.joined(separator: "\n\n")
    }
}
#endif
