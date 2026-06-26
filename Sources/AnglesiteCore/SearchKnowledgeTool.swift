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

    public init(index: SiteKnowledgeIndex, siteID: String) {
        self.index = index
        self.siteID = siteID
    }

    public func call(arguments: Arguments) async throws -> String {
        let query = arguments.query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            return "Provide a project search query."
        }
        let results = await index.search(siteID: siteID, query: query, options: .init(limit: 6))
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
