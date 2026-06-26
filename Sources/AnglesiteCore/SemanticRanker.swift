import Foundation

/// On-device semantic ranking layer over #329's lexical ``SiteKnowledgeIndex``. Holds one
/// embedding vector per document, persisted via ``SemanticIndexCache``. The lexical index is
/// untouched; this is purely additive.
public actor SemanticRanker {
    private struct Stored {
        let contentHash: String
        let vector: [Float]
    }

    private let provider: EmbeddingProvider
    private let cache: SemanticIndexCache?
    /// `[siteID: [docID: Stored]]`.
    private var vectorsBySite: [String: [String: Stored]] = [:]

    public init(provider: EmbeddingProvider, cache: SemanticIndexCache?) {
        self.provider = provider
        self.cache = cache
    }

    /// Text fed to the embedder: title + headings + a leading slice of the body. Document-level
    /// granularity (v0); chunking is a later extension.
    static func embeddedText(for document: SiteKnowledgeIndex.Document) -> String {
        var parts: [String] = []
        if let title = document.title, !title.isEmpty { parts.append(title) }
        if !document.headings.isEmpty { parts.append(document.headings.joined(separator: " ")) }
        parts.append(String(document.excerptText.prefix(2000)))
        return parts.joined(separator: "\n")
    }

    /// Reconciles the vector store for a site against the lexical index's current documents:
    /// reuse cached vectors whose content is unchanged, embed new/changed documents, and drop
    /// vectors for documents that no longer exist.
    public func sync(siteID: String, documents: [SiteKnowledgeIndex.Document]) async {
        // Seed from the cold cache on first touch of this site.
        if vectorsBySite[siteID] == nil, let cache {
            vectorsBySite[siteID] = cache.load(expectedDimension: provider.dimension)
                .mapValues { Stored(contentHash: $0.contentHash, vector: $0.vector) }
        }
        let existing = vectorsBySite[siteID] ?? [:]
        var next: [String: Stored] = [:]
        for document in documents {
            let hash = VectorMath.stableHash(Self.embeddedText(for: document))
            if let prior = existing[document.id], prior.contentHash == hash {
                next[document.id] = prior
            } else if let vector = try? await provider.embed(Self.embeddedText(for: document)) {
                next[document.id] = Stored(contentHash: hash, vector: vector)
            }
        }
        vectorsBySite[siteID] = next
        persist(siteID: siteID)
    }

    /// Re-embeds a single document if its content changed (incremental update during a session).
    public func upsert(siteID: String, document: SiteKnowledgeIndex.Document) async {
        let hash = VectorMath.stableHash(Self.embeddedText(for: document))
        if vectorsBySite[siteID]?[document.id]?.contentHash == hash { return }
        guard let vector = try? await provider.embed(Self.embeddedText(for: document)) else { return }
        vectorsBySite[siteID, default: [:]][document.id] = Stored(contentHash: hash, vector: vector)
        persist(siteID: siteID)
    }

    /// Drops a single document's vector (e.g. its file was deleted).
    public func remove(siteID: String, docID: String) async {
        vectorsBySite[siteID]?[docID] = nil
        persist(siteID: siteID)
    }

    /// Number of vectors held for a site (inspection/tests).
    public func vectorCount(siteID: String) -> Int {
        vectorsBySite[siteID]?.count ?? 0
    }

    private func persist(siteID: String) {
        guard let cache, let stored = vectorsBySite[siteID] else { return }
        let entries = stored.reduce(into: [String: SemanticIndexCache.Entry]()) { result, pair in
            result[pair.key] = SemanticIndexCache.Entry(
                docID: pair.key,
                contentHash: pair.value.contentHash,
                dimension: provider.dimension,
                vector: pair.value.vector)
        }
        try? cache.save(entries)
    }
}
