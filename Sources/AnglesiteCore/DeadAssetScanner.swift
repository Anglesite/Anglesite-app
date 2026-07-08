import Foundation

/// Detects unused `.astro` components/layouts and unused `public/images` assets by building a
/// reference graph from `import` statements, `href`/`src` attributes, markdown image syntax,
/// CSS `url()`, `Astro.glob` calls, and frontmatter `layout:` fields — then finding files with
/// zero resolved inbound references.
///
/// An unresolvable reference (bare specifier, unconfigured path alias) is never counted as proof
/// of use *or* disuse — it is simply skipped. This biases the whole scanner toward
/// under-flagging: the failure mode is "missed a dead file," never "recommended deleting
/// something in use."
public enum DeadAssetScanner {
    public struct CleanupCandidate: Sendable, Equatable, Identifiable {
        public let id: String
        public let path: String
        public let kind: Kind
        public let lastModified: Date
        public let referenceCount: Int

        public enum Kind: String, Sendable, Equatable, CaseIterable {
            case component, layout, image, page
        }

        public init(id: String, path: String, kind: Kind, lastModified: Date, referenceCount: Int) {
            self.id = id
            self.path = path
            self.kind = kind
            self.lastModified = lastModified
            self.referenceCount = referenceCount
        }
    }

    /// Raw references extracted from one source file, already resolved to project-relative paths
    /// where possible. `globDirectories` are directories an `Astro.glob` call covers — every file
    /// under one is treated as referenced, regardless of whether it appears in `fileReferences`.
    struct ReferenceSource: Sendable, Equatable {
        let path: String
        let fileReferences: Set<String>
        let globDirectories: Set<String>
    }

    // MARK: - Regexes (compiled once, matching the style of ContentScanner/SiteKnowledgeIndex)

    private static let importRegex = try! NSRegularExpression(
        pattern: #"import\s+(?:[^'"]+?\s+from\s+)?["']([^"']+)["']"#)
    private static let hrefSrcRegex = try! NSRegularExpression(
        pattern: #"(?:href|src)=["']([^"']+)["']"#, options: [.caseInsensitive])
    private static let markdownImageRegex = try! NSRegularExpression(
        pattern: #"!\[[^\]]*\]\(([^)]+)\)"#)
    private static let cssURLRegex = try! NSRegularExpression(
        pattern: #"url\(\s*['"]?([^'")]+)['"]?\s*\)"#, options: [.caseInsensitive])
    private static let astroGlobRegex = try! NSRegularExpression(
        pattern: #"Astro\.glob\(\s*['"]([^'"]+)['"]"#)

    /// Extracts and resolves every reference in `source`, a file at project-relative `path`.
    static func extractReferences(source: String, path: String) -> ReferenceSource {
        let raw = matches(importRegex, in: source, group: 1)
            + matches(hrefSrcRegex, in: source, group: 1)
            + matches(markdownImageRegex, in: source, group: 1)
            + matches(cssURLRegex, in: source, group: 1)

        var fileRefs = Set<String>()
        for candidate in raw {
            let cleaned = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            if let resolved = resolve(cleaned, relativeTo: path) { fileRefs.insert(resolved) }
        }

        var globDirs = Set<String>()
        for pattern in matches(astroGlobRegex, in: source, group: 1) {
            if let dir = resolveGlobDirectory(pattern, relativeTo: path) { globDirs.insert(dir) }
        }

        return ReferenceSource(path: path, fileReferences: fileRefs, globDirectories: globDirs)
    }

    // MARK: - Path resolution

    /// Resolves a raw reference string to a project-relative path, or `nil` if it can't be
    /// resolved (bare specifier, unconfigured alias) — never guessed at.
    static func resolve(_ ref: String, relativeTo sourcePath: String) -> String? {
        if let abs = resolveAbsolutePath(ref) { return abs }
        if let rel = resolveRelativePath(ref, relativeTo: sourcePath) { return rel }
        return nil
    }

    /// `/images/hero.png` → `public/images/hero.png` (Astro serves `public/` at the site root).
    /// Strips a trailing `?query` or `#fragment` first.
    static func resolveAbsolutePath(_ ref: String) -> String? {
        guard ref.hasPrefix("/") else { return nil }
        var clean = String(ref.dropFirst())
        if let cut = clean.firstIndex(where: { $0 == "?" || $0 == "#" }) {
            clean = String(clean[clean.startIndex..<cut])
        }
        guard !clean.isEmpty else { return nil }
        return "public/" + clean
    }

    /// Resolves `./`/`../`-prefixed `ref` against `sourcePath`'s own directory. Strips a trailing
    /// `?query`/`#fragment` first.
    static func resolveRelativePath(_ ref: String, relativeTo sourcePath: String) -> String? {
        guard ref.hasPrefix("./") || ref.hasPrefix("../") else { return nil }
        var clean = ref
        if let cut = clean.firstIndex(where: { $0 == "?" || $0 == "#" }) {
            clean = String(clean[clean.startIndex..<cut])
        }
        var dirComponents = sourcePath.split(separator: "/").dropLast().map(String.init)
        for segment in clean.split(separator: "/") {
            if segment == "." { continue }
            else if segment == ".." { if !dirComponents.isEmpty { dirComponents.removeLast() } }
            else { dirComponents.append(String(segment)) }
        }
        guard !dirComponents.isEmpty else { return nil }
        return dirComponents.joined(separator: "/")
    }

    /// Truncates an `Astro.glob` pattern down to its containing directory (e.g.
    /// `../content/*.md` → the resolved form of `../content`) and resolves that against
    /// `sourcePath`. Only relative glob patterns are handled — Astro.glob never takes an
    /// absolute-from-public pattern.
    static func resolveGlobDirectory(_ pattern: String, relativeTo sourcePath: String) -> String? {
        guard pattern.hasPrefix("./") || pattern.hasPrefix("../") else { return nil }
        var dir = pattern
        if let starIndex = dir.firstIndex(of: "*") {
            dir = String(dir[dir.startIndex..<starIndex])
            if let lastSlash = dir.lastIndex(of: "/") {
                dir = String(dir[dir.startIndex...lastSlash])
            }
        }
        if dir.hasSuffix("/") { dir.removeLast() }
        return resolveRelativePath(dir, relativeTo: sourcePath)
    }

    private static func matches(_ regex: NSRegularExpression, in source: String, group: Int) -> [String] {
        let range = NSRange(source.startIndex..<source.endIndex, in: source)
        var out: [String] = []
        for match in regex.matches(in: source, range: range) {
            guard let r = Range(match.range(at: group), in: source) else { continue }
            out.append(String(source[r]))
        }
        return out
    }
}
