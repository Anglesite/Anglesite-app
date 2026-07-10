import Foundation

#if compiler(>=6.4)
import FoundationModels
import os

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

    private static let log = Logger(subsystem: "io.dwk.anglesite", category: "SearchKnowledgeTool")

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
        let resultLimit = 6
        // Pull a wider lexical candidate pool than we display, then semantically rerank *within
        // that pool*: a weak-keyword-but-on-topic doc ranked, say, #25 lexically can be lifted into
        // the visible 6. A doc with *zero* lexical overlap is deliberately NOT surfaced here —
        // results carry a lexical excerpt + line range, so synthesizing excerpt-less semantic-only
        // hits belongs to the Related-Pages panel (Plan B), not this cited-excerpt tool.
        let candidatePool = ranker == nil ? resultLimit : 30
        var results = await index.search(siteID: siteID, query: query, options: .init(limit: candidatePool))
        if let ranker, !results.isEmpty {
            // Score broadly, then keep only the lexical candidates' scores — no throwaway work on
            // semantic hits that can't be surfaced anyway.
            let semantic = await ranker.search(siteID: siteID, queryText: query, limit: 200)
            if semantic.isEmpty {
                // No on-device model, or nothing synced yet: degrade to lexical — but say so, since
                // silently dropping ranking quality would violate the project's "logs are sacred".
                Self.log.notice("semantic ranking returned no vectors; using lexical order")
            } else {
                let lexicalScores = Dictionary(results.map { ($0.document.id, $0.score) }, uniquingKeysWith: max)
                let semanticScores = semantic.reduce(into: [String: Double]()) { acc, ranked in
                    if lexicalScores[ranked.docID] != nil { acc[ranked.docID] = Double(ranked.score) }
                }
                let blended = SemanticRanker.blend(lexical: lexicalScores, semantic: semanticScores, semanticWeight: 0.6)
                results = results.sorted {
                    let lhs = blended[$0.document.id] ?? 0, rhs = blended[$1.document.id] ?? 0
                    return lhs != rhs ? lhs > rhs : $0.document.path < $1.document.path
                }
            }
        }
        results = Array(results.prefix(resultLimit))
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
