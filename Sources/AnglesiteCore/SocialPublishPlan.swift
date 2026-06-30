import Foundation

/// Network-free planning for V-2 outbound social publishing.
///
/// The actual Webmention/POSSE sends are gated on `@dwk/workers` readiness. This planner gives
/// the deploy pipeline a deterministic contract: for each publishable content entry, compute the
/// canonical source URL, outbound Webmention targets, and requested POSSE destinations.
public enum SocialPublishPlan {
    public struct Entry: Equatable, Sendable {
        public let sourceFile: String
        public let canonicalURL: URL
        public let webmentionTargets: [URL]
        public let posseTargets: [String]

        public init(
            sourceFile: String,
            canonicalURL: URL,
            webmentionTargets: [URL],
            posseTargets: [String]
        ) {
            self.sourceFile = sourceFile
            self.canonicalURL = canonicalURL
            self.webmentionTargets = webmentionTargets
            self.posseTargets = posseTargets
        }
    }

    public struct Plan: Equatable, Sendable {
        public let entries: [Entry]

        public init(entries: [Entry]) {
            self.entries = entries
        }

        public var isEmpty: Bool { entries.isEmpty }
        public var webmentionCount: Int { entries.reduce(0) { $0 + $1.webmentionTargets.count } }
        public var posseCount: Int { entries.reduce(0) { $0 + $1.posseTargets.count } }
    }

    public enum PlanningError: Error, Equatable, Sendable {
        case invalidSiteBase(String)
    }

    private static let entryExtensions: Set<String> = ["md", "mdx", "mdoc", "markdown"]
    private static let outboundURLPattern = try! NSRegularExpression(
        pattern: #"https?://[^\s<>"'\)\]\}]+"#,
        options: [.caseInsensitive]
    )
    private static let trailingPunctuation = CharacterSet(charactersIn: ".,;:!?")

    /// Builds the outbound-social plan for a site's Astro project root (`Source/`).
    public static func build(projectRoot: URL, siteBase: URL) throws -> Plan {
        guard let baseHost = siteBase.host, siteBase.scheme == "http" || siteBase.scheme == "https" else {
            throw PlanningError.invalidSiteBase(siteBase.absoluteString)
        }

        let contentRoot = projectRoot.appendingPathComponent("src/content", isDirectory: true)
        let files = walk(contentRoot).filter { entryExtensions.contains($0.pathExtension.lowercased()) }
        let entries = files.compactMap { file -> Entry? in
            guard let source = try? String(contentsOf: file, encoding: .utf8) else { return nil }
            let frontmatter = Frontmatter.parse(source)
            if frontmatter["draft"] == .bool(true) { return nil }

            let relPath = relativePosix(file, from: projectRoot)
            guard let canonical = canonicalURL(for: relPath, frontmatter: frontmatter, siteBase: siteBase) else {
                return nil
            }

            let targets = webmentionTargets(in: source, frontmatter: frontmatter, excludingHost: baseHost)
            let posseTargets = posseTargets(in: frontmatter)
            guard !targets.isEmpty || !posseTargets.isEmpty else { return nil }

            return Entry(
                sourceFile: relPath,
                canonicalURL: canonical,
                webmentionTargets: targets,
                posseTargets: posseTargets
            )
        }
        return Plan(entries: entries.sorted { $0.sourceFile < $1.sourceFile })
    }

    private static func canonicalURL(
        for relPath: String,
        frontmatter: [String: FrontmatterValue],
        siteBase: URL
    ) -> URL? {
        let parts = relPath.split(separator: "/").map(String.init)
        guard parts.count >= 4, parts[0] == "src", parts[1] == "content" else { return nil }
        let collection = parts[2]
        let fileName = parts.last ?? ""
        let fallbackSlug = basenameWithoutExtension(fileName)
        let slug = string(frontmatter["slug"]) ?? fallbackSlug
        return URL(string: "/\(collection)/\(slug)/", relativeTo: siteBase)?.absoluteURL
    }

    private static func webmentionTargets(
        in source: String,
        frontmatter: [String: FrontmatterValue],
        excludingHost siteHost: String
    ) -> [URL] {
        var candidates: [URL] = []

        for key in ["inReplyTo", "bookmarkOf", "likeOf", "repostOf"] {
            if let value = string(frontmatter[key]), let url = URL(string: value) {
                candidates.append(url)
            }
        }

        let range = NSRange(source.startIndex..<source.endIndex, in: source)
        for match in outboundURLPattern.matches(in: source, range: range) {
            guard let r = Range(match.range, in: source) else { continue }
            let raw = String(source[r]).trimmingCharacters(in: trailingPunctuation)
            if let url = URL(string: raw) {
                candidates.append(url)
            }
        }

        return unique(candidates.compactMap { url -> URL? in
            guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return nil }
            guard let host = url.host, host.caseInsensitiveCompare(siteHost) != .orderedSame else { return nil }
            return url
        })
    }

    private static func posseTargets(in frontmatter: [String: FrontmatterValue]) -> [String] {
        let keys = ["posse", "syndicateTo", "syndicate-to"]
        let values = keys.flatMap { key -> [String] in
            switch frontmatter[key] {
            case .array(let items): return items
            case .string(let item) where !item.isEmpty: return [item]
            default: return []
            }
        }
        return Array(Set(values.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }))
            .sorted()
    }

    private static func unique(_ urls: [URL]) -> [URL] {
        var seen: Set<String> = []
        var out: [URL] = []
        for url in urls {
            let key = url.absoluteString
            if seen.insert(key).inserted {
                out.append(url)
            }
        }
        return out.sorted { $0.absoluteString < $1.absoluteString }
    }

    private static func string(_ value: FrontmatterValue?) -> String? {
        if case let .string(s)? = value, !s.isEmpty { return s }
        return nil
    }

    private static func basenameWithoutExtension(_ fileName: String) -> String {
        guard let dot = fileName.lastIndex(of: ".") else { return fileName }
        return String(fileName[..<dot])
    }

    private static func walk(_ dir: URL) -> [URL] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.isDirectoryKey], options: []
        ) else { return [] }
        var files: [URL] = []
        for entry in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let isDir = (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if isDir {
                files.append(contentsOf: walk(entry))
            } else {
                files.append(entry)
            }
        }
        return files
    }

    private static func relativePosix(_ url: URL, from base: URL) -> String {
        let urlComponents = url.standardizedFileURL.pathComponents
        let baseComponents = base.standardizedFileURL.pathComponents
        guard urlComponents.starts(with: baseComponents) else { return url.path }
        return urlComponents.dropFirst(baseComponents.count).joined(separator: "/")
    }
}
