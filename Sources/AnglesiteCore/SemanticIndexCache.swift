import Foundation

/// On-disk cache of document embeddings, one file per site under the package's app-owned
/// `Config/caches/` (never in git). Embeddings are expensive to recompute; the lexical index
/// itself stays in-memory (see #329). Invalidation is by `contentHash` (caller-checked) and by
/// `dimension` (checked here on load).
public struct SemanticIndexCache: Sendable {
    public struct Entry: Codable, Equatable, Sendable {
        public let docID: String
        public let contentHash: String
        public let dimension: Int
        public let vector: [Float]

        public init(docID: String, contentHash: String, dimension: Int, vector: [Float]) {
            self.docID = docID
            self.contentHash = contentHash
            self.dimension = dimension
            self.vector = vector
        }
    }

    private let fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    /// Loads `[docID: Entry]`. Entries whose `dimension` differs from `expectedDimension` are
    /// dropped (the provider changed); a single malformed/legacy entry is skipped rather than
    /// discarding the whole cache. A missing file (or one that isn't a JSON array) yields an empty
    /// map — never fatal.
    ///
    /// Performs blocking file I/O on the caller's executor (today that's `SemanticRanker`'s actor).
    /// Acceptable while the cache is unwired in production; move the read off-actor when the
    /// per-site cache is enabled (see `SemanticRanker.persist`).
    public func load(expectedDimension: Int) -> [String: Entry] {
        guard let data = try? Data(contentsOf: fileURL),
              let entries = try? JSONDecoder().decode([LenientEntry].self, from: data) else {
            return [:]
        }
        var out: [String: Entry] = [:]
        for entry in entries.compactMap(\.entry) where entry.dimension == expectedDimension {
            out[entry.docID] = entry
        }
        return out
    }

    /// Decodes an array element to `Entry?`, swallowing a per-element decode failure so one bad
    /// entry doesn't fail the whole-array decode.
    private struct LenientEntry: Decodable {
        let entry: Entry?
        init(from decoder: Decoder) throws {
            entry = try? Entry(from: decoder)
        }
    }

    /// Atomically writes the entries, creating the parent directory if needed.
    public func save(_ entries: [String: Entry]) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(entries.values.sorted { $0.docID < $1.docID })
        try data.write(to: fileURL, options: .atomic)
    }
}
