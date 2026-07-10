import Foundation

/// One page/post of a site reduced to capped plain text for a single FM call (#465). `filePath`
/// is project-relative (e.g. `src/pages/about.astro`) so findings can be applied back to disk.
public struct ContentChunk: Sendable, Equatable, Identifiable {
    public var id: String { filePath }
    public let route: String
    public let title: String?
    public let filePath: String
    public let text: String
    public let truncated: Bool

    public init(route: String, title: String?, filePath: String, text: String, truncated: Bool) {
        self.route = route
        self.title = title
        self.filePath = filePath
        self.text = text
        self.truncated = truncated
    }
}

/// Deterministic whole-site enumeration for the content-help capabilities: scans the `Source/`
/// tree directly (the same filesystem truth `SiteContentGraph` is populated from), extracts
/// plain text per file, and hard-caps each chunk so every FM call fits the ~4K on-device window
/// (the spec's chunk-first strategy). Pure string helpers are separated for CI unit tests.
public enum SiteContentChunker {
    /// Matches `FoundationModelAssistant.maxPageContentCharacters` — a char-based token proxy.
    public static let maxChunkCharacters = 2_000

    static let contentExtensions: Set<String> = ["md", "mdoc"]
    static let pageExtensions: Set<String> = ["astro", "md", "mdoc"]

    public static func chunks(sourceDirectory: URL, fileManager: FileManager = .default) -> [ContentChunk] {
        var chunks: [ContentChunk] = []
        for (subdir, extensions) in [("src/content", contentExtensions), ("src/pages", pageExtensions)] {
            let root = sourceDirectory.appendingPathComponent(subdir)
            guard let enumerator = fileManager.enumerator(
                at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { continue }
            for case let url as URL in enumerator {
                guard extensions.contains(url.pathExtension.lowercased()),
                      let contents = try? String(contentsOf: url, encoding: .utf8) else { continue }
                let relative = subdir + "/" + relativePath(of: url, under: root)
                let fields = Frontmatter.parse(contents)
                var title: String?
                if case let .string(value)? = fields["title"] { title = value }
                let raw = url.pathExtension.lowercased() == "astro"
                    ? plainText(astro: contents) : plainText(markdown: Frontmatter.body(contents))
                guard !raw.isEmpty else { continue }
                let (text, truncated) = capped(raw)
                chunks.append(ContentChunk(
                    route: route(forRelativePath: relative),
                    title: title,
                    filePath: relative,
                    text: text,
                    truncated: truncated
                ))
            }
        }
        return chunks.sorted { $0.route < $1.route }
    }

    private static func relativePath(of url: URL, under root: URL) -> String {
        let rootPath = root.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        return path.hasPrefix(rootPath + "/") ? String(path.dropFirst(rootPath.count + 1)) : url.lastPathComponent
    }

    /// `src/pages/about.astro` → `/about`; `src/pages/index.astro` → `/`;
    /// `src/content/posts/my-trip.mdoc` → `/posts/my-trip`.
    public static func route(forRelativePath relative: String) -> String {
        var path = relative
        for prefix in ["src/pages/", "src/content/"] where path.hasPrefix(prefix) {
            path = String(path.dropFirst(prefix.count))
        }
        path = (path as NSString).deletingPathExtension
        if path == "index" || path.isEmpty { return "/" }
        if path.hasSuffix("/index") { path = String(path.dropLast("/index".count)) }
        return "/" + path
    }

    /// Frontmatter-stripped markdown → readable text: link labels kept (URLs dropped), heading
    /// markers / emphasis / list bullets / code fences removed. Enough for a copy audit; not a
    /// markdown renderer.
    public static func plainText(markdown body: String) -> String {
        var text = body
        text = text.replacingOccurrences(of: #"\[([^\]]*)\]\([^)]*\)"#, with: "$1", options: .regularExpression)
        text = text.replacingOccurrences(of: #"(?m)^```.*$"#, with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: #"(?m)^#{1,6}\s*"#, with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: #"(?m)^\s*[-*+]\s+"#, with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: #"[*_`]"#, with: "", options: .regularExpression)
        return collapsed(text)
    }

    /// `.astro` source → inline human text: frontmatter fence (via `Frontmatter.body`, the same
    /// fence detection `parse` uses), `<script>`/`<style>` blocks, tags, and `{…}` expressions
    /// removed. A tag-strip extractor, not an HTML parser — the spec's v1 answer to the
    /// "no HTML→text in Core" gap.
    public static func plainText(astro source: String) -> String {
        var text = Frontmatter.body(source)
        for block in ["script", "style"] {
            text = text.replacingOccurrences(
                of: "<\(block)[\\s\\S]*?</\(block)>", with: " ", options: [.regularExpression, .caseInsensitive])
        }
        text = text.replacingOccurrences(of: #"<[^>]+>"#, with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: #"\{[^}]*\}"#, with: " ", options: .regularExpression)
        return collapsed(text)
    }

    public static func capped(_ text: String) -> (text: String, truncated: Bool) {
        guard text.count > maxChunkCharacters else { return (text, false) }
        return (String(text.prefix(maxChunkCharacters)) + "…", true)
    }

    private static func collapsed(_ text: String) -> String {
        text.replacingOccurrences(of: #"[ \t]+"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
