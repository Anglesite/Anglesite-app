// Sources/AnglesiteCore/ProjectConventionsStore.swift
import Foundation

/// Per-site persistence for `ProjectConventions`, at `<configDirectory>/conventions.json`.
/// Follows `ChatHistoryStore`'s precedent: `Config/` is app-owned and not git-tracked. Unlike
/// `ChatHistoryStore` (append-only JSONL), this is a single whole-value JSON file — there's one
/// current `ProjectConventions`, not a history of them.
public actor ProjectConventionsStore {
    private let fileURL: URL
    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(configDirectory: URL, fileManager: FileManager = .default) {
        self.fileURL = configDirectory.appendingPathComponent("conventions.json")
        self.fileManager = fileManager
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        self.encoder = encoder
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
    }

    public func load() -> ProjectConventions? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? decoder.decode(ProjectConventions.self, from: data)
    }

    public func save(_ conventions: ProjectConventions) {
        guard let data = try? encoder.encode(conventions) else { return }
        try? fileManager.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try? data.write(to: fileURL, options: .atomic)
    }
}
