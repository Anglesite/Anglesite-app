import Foundation

/// A lightweight value type representing one file cited during RAG retrieval. Carries enough
/// for the chat UI to render a chip and navigate to the file without reaching back into the index.
public struct RetrievedCitation: Sendable, Equatable, Identifiable {
    public let id: String
    public let path: String
    public let kind: SiteKnowledgeIndex.Document.Kind
    public let title: String?
    public let lineRange: ClosedRange<Int>?
    public let score: Double

    public init(id: String, path: String, kind: SiteKnowledgeIndex.Document.Kind, title: String?, lineRange: ClosedRange<Int>?, score: Double) {
        self.id = id
        self.path = path
        self.kind = kind
        self.title = title
        self.lineRange = lineRange
        self.score = score
    }

    public init(_ result: SiteKnowledgeIndex.SearchResult) {
        self.init(
            id: result.document.id,
            path: result.document.path,
            kind: result.document.kind,
            title: result.document.title,
            lineRange: result.lineRange,
            score: result.score
        )
    }
}
