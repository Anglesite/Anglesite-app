import Foundation

/// Reads/writes `Source/redirects.json` — a git-tracked, ordered list of source→destination
/// path redirects for a site. Unlike `SiteConfigStore`/`ProjectConventionsStore`, this is rooted
/// at `sourceDirectory` (the `Source/` git repo), not `Config/`: redirects are site content, not
/// app-owned state, so they travel with the repo (see the design spec's §1).
///
/// A template-side Astro integration (`scripts/redirects.ts`) is the sole consumer at build time;
/// this type only owns the read/write/validate contract the app's Redirects UI and the delete
/// flow use to produce that file.
public struct RedirectsStore: Sendable {
    public struct RedirectEntry: Sendable, Equatable, Codable, Identifiable {
        public enum Code: Int, Sendable, Codable, CaseIterable {
            case permanent = 301
            case temporary = 302
        }

        public var id: String { source }
        public var source: String
        public var destination: String
        public var code: Code

        public init(source: String, destination: String, code: Code = .permanent) {
            self.source = source
            self.destination = destination
            self.code = code
        }
    }

    public enum ValidationError: Error, Equatable {
        case sourceMustStartWithSlash(String)
        case duplicateSource(String)
        /// A direct cycle: either `source == destination`, or an existing entry's destination is
        /// this entry's source and vice versa. Deep chains (A→B→C) are not resolved or rejected —
        /// matches Cloudflare's own behavior of following each hop independently.
        case cycle(String, String)
    }

    private let fileURL: URL
    private let fileManager: FileManager

    public init(sourceDirectory: URL, fileManager: FileManager = .default) {
        self.fileURL = sourceDirectory.appendingPathComponent("redirects.json")
        self.fileManager = fileManager
    }

    /// `[]` (not a throw) when the file is absent — the normal "no redirects yet" case for a
    /// freshly scaffolded site.
    public func load() throws -> [RedirectEntry] {
        guard fileManager.fileExists(atPath: fileURL.path) else { return [] }
        let data = try Data(contentsOf: fileURL)
        return try JSONDecoder().decode([RedirectEntry].self, from: data)
    }

    public func save(_ entries: [RedirectEntry]) throws {
        try Self.validate(entries)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(entries)
        try data.write(to: fileURL, options: .atomic)
    }

    public static func validate(_ entries: [RedirectEntry]) throws {
        var seenSources = Set<String>()
        var destinationBySource: [String: String] = [:]
        for entry in entries {
            guard entry.source.hasPrefix("/") else {
                throw ValidationError.sourceMustStartWithSlash(entry.source)
            }
            guard !seenSources.contains(entry.source) else {
                throw ValidationError.duplicateSource(entry.source)
            }
            seenSources.insert(entry.source)
            destinationBySource[entry.source] = entry.destination
        }
        for entry in entries {
            if entry.source == entry.destination {
                throw ValidationError.cycle(entry.source, entry.destination)
            }
            if destinationBySource[entry.destination] == entry.source {
                throw ValidationError.cycle(entry.source, entry.destination)
            }
        }
    }
}
