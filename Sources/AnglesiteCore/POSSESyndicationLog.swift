import Foundation

/// Durable per-site POSSE ledger. Recording the returned social URL before source write-back means
/// a crash cannot silently duplicate the post: the next deploy retries write-back from this ledger.
public struct POSSESyndicationLog: Equatable, Sendable {
    public struct Entry: Codable, Equatable, Sendable {
        public let sourceFile: String
        public let canonicalURL: URL
        public let platform: String
        public let syndicationURL: URL
        public let postedAt: Date
        public var backfeedSentAt: Date?

        public init(
            sourceFile: String,
            canonicalURL: URL,
            platform: String,
            syndicationURL: URL,
            postedAt: Date,
            backfeedSentAt: Date? = nil
        ) {
            self.sourceFile = sourceFile
            self.canonicalURL = canonicalURL
            self.platform = platform
            self.syndicationURL = syndicationURL
            self.postedAt = postedAt
            self.backfeedSentAt = backfeedSentAt
        }
    }

    public static let filename = "posse-syndication.json"
    public var entries: [Entry]

    public init(entries: [Entry] = []) { self.entries = entries }

    private struct Envelope: Codable { let entries: [Entry] }

    public static func load(from configDirectory: URL) -> POSSESyndicationLog? {
        guard let data = try? Data(contentsOf: configDirectory.appendingPathComponent(filename)) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let envelope = try? decoder.decode(Envelope.self, from: data) else { return nil }
        return POSSESyndicationLog(entries: envelope.entries)
    }

    public func save(to configDirectory: URL) throws {
        try FileManager.default.createDirectory(at: configDirectory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(Envelope(entries: entries))
        try data.write(to: configDirectory.appendingPathComponent(Self.filename), options: .atomic)
    }

    public func contains(canonicalURL: URL, platform: String) -> Bool {
        entries.contains { $0.canonicalURL == canonicalURL && $0.platform == platform }
    }

    public mutating func record(_ entry: Entry) {
        guard !contains(canonicalURL: entry.canonicalURL, platform: entry.platform) else { return }
        entries.append(entry)
    }

    public mutating func markBackfeedSent(for entry: Entry, at date: Date) {
        guard let index = entries.firstIndex(where: {
            $0.canonicalURL == entry.canonicalURL && $0.platform == entry.platform
        }) else { return }
        entries[index].backfeedSentAt = date
    }
}
