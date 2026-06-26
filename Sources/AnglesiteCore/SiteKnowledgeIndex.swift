import Foundation

/// A project-local lexical retrieval index for an Astro site.
///
/// The index is intentionally lightweight: it scans source-like files under the active site
/// directory, skips generated/dependency folders, caches file metadata, and returns bounded
/// excerpts ranked by query-term overlap. It gives every assistant backend the same local context
/// without requiring a network embedding service or a provider-specific tool.
public actor SiteKnowledgeIndex {
    public struct Match: Sendable, Equatable {
        public let relativePath: String
        public let lineRange: ClosedRange<Int>
        public let score: Int
        public let excerpt: String

        public init(relativePath: String, lineRange: ClosedRange<Int>, score: Int, excerpt: String) {
            self.relativePath = relativePath
            self.lineRange = lineRange
            self.score = score
            self.excerpt = excerpt
        }
    }

    public struct Options: Sendable, Equatable {
        public let maxFileBytes: UInt64
        public let maxResults: Int
        public let excerptRadius: Int
        public let maxExcerptCharacters: Int

        public init(
            maxFileBytes: UInt64 = 256 * 1024,
            maxResults: Int = 6,
            excerptRadius: Int = 3,
            maxExcerptCharacters: Int = 1_200
        ) {
            self.maxFileBytes = maxFileBytes
            self.maxResults = maxResults
            self.excerptRadius = excerptRadius
            self.maxExcerptCharacters = maxExcerptCharacters
        }
    }

    private struct IndexedFile: Sendable, Equatable {
        let relativePath: String
        let modifiedAt: Date
        let byteSize: UInt64
        let content: String
        let tokens: Set<String>
    }

    private let siteDirectory: URL
    private let options: Options
    private var files: [String: IndexedFile] = [:]
    private var lastRefresh: Date?

    private static let indexedExtensions: Set<String> = [
        "astro", "md", "mdx", "html", "css", "scss",
        "js", "jsx", "ts", "tsx", "json", "jsonc", "yaml", "yml", "toml",
    ]

    private static let skippedDirectoryNames: Set<String> = [
        ".astro", ".git", ".netlify", ".wrangler", ".vercel",
        "build", "coverage", "dist", "node_modules", "out",
    ]

    public init(siteDirectory: URL, options: Options = Options()) {
        self.siteDirectory = siteDirectory.standardizedFileURL
        self.options = options
    }

    /// Refreshes the cache from disk. This is cheap for unchanged files: only metadata is checked
    /// before preserving an existing `IndexedFile`.
    public func refresh() {
        let discovered = discoverIndexableFiles()
        var next: [String: IndexedFile] = [:]

        for url in discovered {
            guard let relativePath = relativePath(for: url),
                  let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
                  let byteSize = (attributes[.size] as? NSNumber)?.uint64Value,
                  byteSize <= options.maxFileBytes
            else { continue }
            let modifiedAt = (attributes[.modificationDate] as? Date) ?? .distantPast

            if let existing = files[relativePath],
               existing.modifiedAt == modifiedAt,
               existing.byteSize == byteSize {
                next[relativePath] = existing
                continue
            }

            guard let data = try? Data(contentsOf: url),
                  let content = String(data: data, encoding: .utf8)
            else { continue }
            next[relativePath] = IndexedFile(
                relativePath: relativePath,
                modifiedAt: modifiedAt,
                byteSize: byteSize,
                content: content,
                tokens: Self.tokens(in: relativePath + "\n" + content)
            )
        }

        files = next
        lastRefresh = Date()
    }

    /// Retrieves project context for a user request. Calls `refresh()` first so disk edits made by
    /// the app, MCP, or another editor are visible on the next assistant turn.
    public func search(_ query: String) -> [Match] {
        refresh()
        let queryTokens = Self.tokens(in: query)
        guard !queryTokens.isEmpty else { return [] }

        return files.values.compactMap { file -> Match? in
            let overlap = file.tokens.intersection(queryTokens)
            guard !overlap.isEmpty else { return nil }
            let lineMatch = bestLineMatch(in: file.content, queryTokens: queryTokens)
            let score = overlap.count * 10 + lineMatch.score
            return Match(
                relativePath: file.relativePath,
                lineRange: lineMatch.range,
                score: score,
                excerpt: excerpt(from: file.content, around: lineMatch.range)
            )
        }
        .sorted {
            if $0.score != $1.score { return $0.score > $1.score }
            return $0.relativePath < $1.relativePath
        }
        .prefix(options.maxResults)
        .map { $0 }
    }

    public func formattedContext(for query: String) -> String? {
        let matches = search(query)
        guard !matches.isEmpty else { return nil }
        var lines = [
            "Relevant project context retrieved from this Astro site:",
            "Use this context when it is relevant. Cite file paths when answering.",
        ]
        for match in matches {
            let lineLabel = match.lineRange.lowerBound == match.lineRange.upperBound
                ? "line \(match.lineRange.lowerBound)"
                : "lines \(match.lineRange.lowerBound)-\(match.lineRange.upperBound)"
            lines.append("\n[\(match.relativePath):\(lineLabel)]")
            lines.append(match.excerpt)
        }
        return lines.joined(separator: "\n")
    }

    private func discoverIndexableFiles() -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: siteDirectory,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var urls: [URL] = []
        for case let url as URL in enumerator {
            if isSkippedDirectory(url) {
                enumerator.skipDescendants()
                continue
            }
            guard isIndexableFile(url) else { continue }
            urls.append(url)
        }
        return urls
    }

    private func isSkippedDirectory(_ url: URL) -> Bool {
        guard (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
            return false
        }
        return Self.skippedDirectoryNames.contains(url.lastPathComponent)
    }

    private func isIndexableFile(_ url: URL) -> Bool {
        guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
            return false
        }
        return Self.indexedExtensions.contains(url.pathExtension.lowercased())
    }

    private func relativePath(for url: URL) -> String? {
        let base = siteDirectory.path
        let path = url.standardizedFileURL.path
        guard path == base || path.hasPrefix(base + "/") else { return nil }
        return String(path.dropFirst(base.count + 1))
    }

    private func bestLineMatch(in content: String, queryTokens: Set<String>) -> (range: ClosedRange<Int>, score: Int) {
        let lines = content.components(separatedBy: .newlines)
        var bestLine = 1
        var bestScore = 0

        for (index, line) in lines.enumerated() {
            let lineTokens = Self.tokens(in: line)
            let score = lineTokens.intersection(queryTokens).count
            if score > bestScore {
                bestScore = score
                bestLine = index + 1
            }
        }

        let start = max(1, bestLine - options.excerptRadius)
        let end = min(max(1, lines.count), bestLine + options.excerptRadius)
        return (start...end, bestScore)
    }

    private func excerpt(from content: String, around range: ClosedRange<Int>) -> String {
        let lines = content.components(separatedBy: .newlines)
        let excerpt = range.compactMap { lineNumber -> String? in
            guard lines.indices.contains(lineNumber - 1) else { return nil }
            return "\(lineNumber): \(lines[lineNumber - 1])"
        }.joined(separator: "\n")
        guard excerpt.count > options.maxExcerptCharacters else { return excerpt }
        let end = excerpt.index(excerpt.startIndex, offsetBy: options.maxExcerptCharacters)
        return String(excerpt[..<end]) + "\n..."
    }

    private static func tokens(in text: String) -> Set<String> {
        let normalized = splitCamelCase(in: text).lowercased()
        let parts = normalized.split { character in
            !character.isLetter && !character.isNumber
        }
        let tokens = parts.map(String.init).filter { $0.count >= 2 && !stopWords.contains($0) }
        return Set(tokens)
    }

    private static func splitCamelCase(in text: String) -> String {
        var output = ""
        var previousWasLowercaseOrNumber = false
        for scalar in text.unicodeScalars {
            let character = Character(scalar)
            if previousWasLowercaseOrNumber && CharacterSet.uppercaseLetters.contains(scalar) {
                output.append(" ")
            }
            output.append(character)
            previousWasLowercaseOrNumber = CharacterSet.lowercaseLetters.contains(scalar)
                || CharacterSet.decimalDigits.contains(scalar)
        }
        return output
    }

    private static let stopWords: Set<String> = [
        "a", "an", "and", "are", "as", "at", "be", "by", "for", "from",
        "how", "in", "is", "it", "my", "of", "on", "or", "that", "the",
        "this", "to", "use", "what", "where", "why", "with", "your",
    ]
}
