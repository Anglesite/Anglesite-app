import Foundation
import Testing
@testable import AnglesiteCore

@Suite("SemanticIndexCache")
struct SemanticIndexCacheTests {
    private func tempCacheURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("sem-cache-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("caches/semantic-index.json")
    }

    @Test("save then load round-trips entries")
    func roundTrip() throws {
        let cache = SemanticIndexCache(fileURL: tempCacheURL())
        let entry = SemanticIndexCache.Entry(docID: "s:doc:a", contentHash: "abc", dimension: 8, vector: [0, 1, 0, 0, 0, 0, 0, 0])
        try cache.save(["s:doc:a": entry])
        let loaded = cache.load(expectedDimension: 8)
        #expect(loaded == ["s:doc:a": entry])
    }

    @Test("load drops entries with mismatched dimension")
    func dropsWrongDimension() throws {
        let cache = SemanticIndexCache(fileURL: tempCacheURL())
        let entry = SemanticIndexCache.Entry(docID: "s:doc:a", contentHash: "abc", dimension: 8, vector: [0, 1, 0, 0, 0, 0, 0, 0])
        try cache.save(["s:doc:a": entry])
        #expect(cache.load(expectedDimension: 16).isEmpty)
    }

    @Test("load returns empty for a missing file")
    func missingFile() {
        let cache = SemanticIndexCache(fileURL: tempCacheURL())
        #expect(cache.load(expectedDimension: 8).isEmpty)
    }

    @Test("load returns empty for a corrupt file")
    func corruptFile() throws {
        let url = tempCacheURL()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: url)
        #expect(SemanticIndexCache(fileURL: url).load(expectedDimension: 8).isEmpty)
    }
}
