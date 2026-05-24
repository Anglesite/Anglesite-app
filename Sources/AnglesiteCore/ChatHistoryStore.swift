import Foundation

/// Per-site chat history persisted to `<siteDirectory>/.anglesite/chat-history.jsonl` (per the
/// build-plan cross-cutting decision). Append-only JSONL — one record per line — so the file
/// stays usable from the command line (`tail -f`, `grep`, `jq`) and from other tools that
/// might want to read the history without going through Anglesite.
///
/// Atomicity: appends use `FileHandle.write(_:)` after seeking to end. We don't rotate or
/// truncate; the file is expected to grow slowly enough that disk pressure isn't a concern
/// for v0.5. (Bigger sites can `truncate -s 0 .anglesite/chat-history.jsonl` manually.)
public actor ChatHistoryStore {
    public enum Role: String, Sendable, Codable, Equatable {
        case user
        case assistant
        case tool
    }

    /// One persisted line. The shape is intentionally narrow so it survives schema changes —
    /// `metadata` carries optional extras (toolUseID, isError, model, etc.) without bloating
    /// the top-level fields.
    public struct Entry: Sendable, Codable, Equatable {
        public let timestamp: Date
        public let role: Role
        public let content: String
        public let metadata: [String: String]?

        public init(timestamp: Date = Date(), role: Role, content: String, metadata: [String: String]? = nil) {
            self.timestamp = timestamp
            self.role = role
            self.content = content
            self.metadata = metadata
        }
    }

    public let fileURL: URL
    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(siteDirectory: URL, fileManager: FileManager = .default) {
        self.fileURL = siteDirectory
            .appendingPathComponent(".anglesite", isDirectory: true)
            .appendingPathComponent("chat-history.jsonl")
        self.fileManager = fileManager
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        // Each entry is one JSONL line — no pretty-printing.
        self.encoder = encoder
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
    }

    /// Load every entry from the history file, in write order. Returns an empty array if the
    /// file doesn't exist yet (a brand-new site has no history).
    public func load() throws -> [Entry] {
        guard fileManager.fileExists(atPath: fileURL.path) else { return [] }
        let data = try Data(contentsOf: fileURL)
        guard !data.isEmpty else { return [] }
        var entries: [Entry] = []
        // Decode line by line so a single corrupt line (e.g. from a partial write) doesn't
        // destroy the whole history.
        for line in data.split(separator: 0x0A, omittingEmptySubsequences: true) {
            guard let entry = try? decoder.decode(Entry.self, from: Data(line)) else { continue }
            entries.append(entry)
        }
        return entries
    }

    /// Append one entry. Creates `<site>/.anglesite/` and the history file if missing.
    public func append(_ entry: Entry) throws {
        let parent = fileURL.deletingLastPathComponent()
        if !fileManager.fileExists(atPath: parent.path) {
            try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
        }
        if !fileManager.fileExists(atPath: fileURL.path) {
            fileManager.createFile(atPath: fileURL.path, contents: nil)
        }
        var data = try encoder.encode(entry)
        data.append(0x0A)  // newline terminator — JSONL convention
        let handle = try FileHandle(forWritingTo: fileURL)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
    }

    /// Truncate the history file. Used by "Reset conversation" in the UI.
    public func clear() throws {
        guard fileManager.fileExists(atPath: fileURL.path) else { return }
        try Data().write(to: fileURL, options: .atomic)
    }
}
