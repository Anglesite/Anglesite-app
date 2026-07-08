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
///
/// **Known limitation:** brace-bound dynamic references (`<img src={heroPath}>`,
/// `<Image src={imported} />`), dynamic `import(...)` calls, and re-export barrels
/// (`export … from`) are not matched by the regex-based extraction below — a file referenced
/// *only* through one of these patterns can be incorrectly flagged as unused. This is an
/// inherent tradeoff of regex-based scanning versus a full AST parse and is not closed here;
/// Delete always requires explicit user confirmation and is git-tracked/recoverable, which is
/// this scanner's primary mitigation for this class of false positive.
///
/// **Alias resolution scope:** `tsconfig.json`/`jsconfig.json` `compilerOptions.paths` (wildcard
/// and exact entries), `baseUrl`, and a same-project `extends` chain are resolved (see
/// `loadPathAliases`/`resolveAlias`). Aliases declared *only* via `astro.config.mjs`'s
/// `vite.resolve.alias` — not mirrored into tsconfig/jsconfig `paths`, which Astro's docs
/// recommend keeping in sync but do not enforce — are **not** resolved: an import through such an
/// alias with no matching `paths` entry stays unresolved and can flag a live file as unused. Same
/// mitigation as the regex blind spots above: confirmation-gated, git-tracked delete.
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
        let unresolvedReferences: Set<String>
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
        var unresolved = Set<String>()
        for candidate in raw {
            let cleaned = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            if let resolved = resolve(cleaned, relativeTo: path) {
                fileRefs.insert(resolved)
            } else {
                unresolved.insert(cleaned)
            }
        }

        var globDirs = Set<String>()
        for pattern in matches(astroGlobRegex, in: source, group: 1) {
            if let dir = resolveGlobDirectory(pattern, relativeTo: path) { globDirs.insert(dir) }
        }

        return ReferenceSource(
            path: path, fileReferences: fileRefs, globDirectories: globDirs,
            unresolvedReferences: unresolved)
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

    /// A tsconfig/jsconfig's alias-relevant `compilerOptions`, merged across an `extends` chain
    /// (a child's own `baseUrl`/`paths` win over anything inherited — matching how TypeScript
    /// itself merges `compilerOptions`). `baseUrl` is stored exactly as written in the config
    /// (project-root-relative in the common case).
    struct PathAliasConfig: Equatable {
        let baseUrl: String?
        let paths: [String: [String]]
    }

    /// Loads `tsconfig.json` or `jsconfig.json` from `projectRoot` (in that order — the first one
    /// that yields a non-empty `baseUrl`/`paths`, after following its `extends` chain, wins).
    /// Malformed/missing/commented JSON safely degrades to an empty config, matching this
    /// scanner's "never guess" resolution philosophy.
    static func loadPathAliases(projectRoot: URL) -> PathAliasConfig {
        for name in ["tsconfig.json", "jsconfig.json"] {
            let url = projectRoot.appendingPathComponent(name)
            if let config = loadTSConfig(at: url, depth: 0), config.baseUrl != nil || !config.paths.isEmpty {
                return config
            }
        }
        return PathAliasConfig(baseUrl: nil, paths: [:])
    }

    /// Loads one tsconfig/jsconfig file, recursively following a relative `extends` chain (TS
    /// resolves `extends` relative to the extending file's own directory; a depth guard avoids an
    /// accidental cycle). Returns `nil` only if `url` itself can't be read/parsed as JSON.
    private static func loadTSConfig(at url: URL, depth: Int) -> PathAliasConfig? {
        guard depth < 5 else { return nil }
        guard let data = try? Data(contentsOf: url) else { return nil }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }

        var inherited = PathAliasConfig(baseUrl: nil, paths: [:])
        if let extendsRef = json["extends"] as? String {
            let parentURL = url.deletingLastPathComponent().appendingPathComponent(extendsRef)
            if let parent = loadTSConfig(at: parentURL, depth: depth + 1) {
                inherited = parent
            }
        }

        let compilerOptions = json["compilerOptions"] as? [String: Any]
        let baseUrl = (compilerOptions?["baseUrl"] as? String) ?? inherited.baseUrl
        var paths = inherited.paths
        if let rawPaths = compilerOptions?["paths"] as? [String: Any] {
            for (pattern, targets) in rawPaths {
                guard let targetList = targets as? [String] else { continue }
                paths[pattern] = targetList
            }
        }
        return PathAliasConfig(baseUrl: baseUrl, paths: paths)
    }

    /// Resolves `ref` against `config` (from `loadPathAliases`): finds a `paths` pattern —
    /// wildcard (single `*`) or exact — matching `ref`, substitutes the corresponding target
    /// (first target wins, matching TypeScript's own resolution order), then resolves that target
    /// relative to `baseUrl` (or, when `baseUrl` is unset, relative to the project root directly —
    /// matching how TypeScript resolves `paths` without an explicit `baseUrl`).
    static func resolveAlias(_ ref: String, config: PathAliasConfig) -> String? {
        for (pattern, targets) in config.paths {
            let starCount = pattern.filter({ $0 == "*" }).count
            if starCount == 1, let starIndex = pattern.firstIndex(of: "*") {
                let prefix = String(pattern[pattern.startIndex..<starIndex])
                let suffix = String(pattern[pattern.index(after: starIndex)...])
                guard ref.hasPrefix(prefix), ref.hasSuffix(suffix), ref.count >= prefix.count + suffix.count else { continue }
                let matched = String(ref.dropFirst(prefix.count).dropLast(suffix.count))
                for target in targets {
                    guard let targetStar = target.firstIndex(of: "*"), target.filter({ $0 == "*" }).count == 1 else { continue }
                    let targetPrefix = String(target[target.startIndex..<targetStar])
                    let targetSuffix = String(target[target.index(after: targetStar)...])
                    let resolved = targetPrefix + matched + targetSuffix
                    return applyBaseURL(resolved, config.baseUrl)
                }
            } else if starCount == 0, pattern == ref, let target = targets.first {
                return applyBaseURL(target, config.baseUrl)
            }
        }
        return nil
    }

    /// Prefixes `target` (a `paths`-substituted specifier, possibly still `./`-relative) with
    /// `baseUrl` when one is configured; strips a leading `./` either way. `baseUrl` is treated as
    /// project-root-relative (the common single-tsconfig case); an `extends` chain that reaches a
    /// parent config outside the project root and sets its own `baseUrl` would misresolve here —
    /// an accepted, narrow gap, no worse than the pre-existing no-`baseUrl` behavior.
    private static func applyBaseURL(_ target: String, _ baseUrl: String?) -> String {
        var clean = target
        if clean.hasPrefix("./") { clean.removeFirst(2) }
        guard let baseUrl, !baseUrl.isEmpty, baseUrl != "." else { return clean }
        var base = baseUrl
        if base.hasPrefix("./") { base.removeFirst(2) }
        if base.hasSuffix("/") { base.removeLast() }
        return "\(base)/\(clean)"
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

    // MARK: - Full-project scan

    private static let referenceScanExtensions: Set<String> = [
        ".astro", ".md", ".mdx", ".mdoc", ".markdown", ".css",
    ]
    private static let excludedDirNames: Set<String> = ["node_modules", "dist", ".astro", ".git"]

    /// Scans every `.astro`/`.md`/`.mdx`/`.mdoc`/`.markdown`/`.css` file under `projectRoot` for
    /// references, then returns every unused `src/components/**/*.astro`, `src/layouts/**/*.astro`,
    /// and unused entry in `images` (typically `SiteContentGraph.images(for:)`, scoped to
    /// `public/images/**`). Pure over the filesystem snapshot at call time.
    public static func scan(projectRoot: URL, images: [SiteContentGraph.Image]) -> [CleanupCandidate] {
        var fileReferenceCounts: [String: Int] = [:]
        var globDirectories: Set<String> = []
        let aliasConfig = loadPathAliases(projectRoot: projectRoot)

        for abs in walk(projectRoot) {
            let ext = "." + abs.pathExtension.lowercased()
            guard referenceScanExtensions.contains(ext) else { continue }
            guard let size = fileSize(abs), size <= 512_000 else { continue }
            guard let source = try? String(contentsOf: abs, encoding: .utf8) else { continue }
            let relPath = relativePosix(abs, from: projectRoot)

            let refs = extractReferences(source: source, path: relPath)
            for ref in refs.fileReferences { fileReferenceCounts[ref.lowercased(), default: 0] += 1 }
            globDirectories.formUnion(refs.globDirectories.map { $0.lowercased() })
            for raw in refs.unresolvedReferences {
                if let aliasResolved = resolveAlias(raw, config: aliasConfig) {
                    fileReferenceCounts[aliasResolved.lowercased(), default: 0] += 1
                }
            }

            // Frontmatter `layout:` counts as a reference too — extractReferences only looks at
            // the body, not frontmatter fields.
            let frontmatter = Frontmatter.parse(source)
            if case let .string(layoutRef)? = frontmatter["layout"],
               let resolved = resolve(layoutRef, relativeTo: relPath) {
                fileReferenceCounts[resolved.lowercased(), default: 0] += 1
            }
        }

        func referenceCount(for path: String) -> Int {
            let key = path.lowercased()
            if globDirectories.contains(where: { key.hasPrefix($0 + "/") }) {
                return max(1, fileReferenceCounts[key] ?? 0)
            }
            return fileReferenceCounts[key] ?? 0
        }

        var candidates: [CleanupCandidate] = []

        for abs in walk(projectRoot.appendingPathComponent("src/components"))
        where abs.pathExtension.lowercased() == "astro" {
            let rel = relativePosix(abs, from: projectRoot)
            let count = referenceCount(for: rel)
            if count == 0 {
                candidates.append(CleanupCandidate(
                    id: rel, path: rel, kind: .component, lastModified: mtime(abs), referenceCount: count))
            }
        }
        for abs in walk(projectRoot.appendingPathComponent("src/layouts"))
        where abs.pathExtension.lowercased() == "astro" {
            let rel = relativePosix(abs, from: projectRoot)
            let count = referenceCount(for: rel)
            if count == 0 {
                candidates.append(CleanupCandidate(
                    id: rel, path: rel, kind: .layout, lastModified: mtime(abs), referenceCount: count))
            }
        }
        for image in images {
            let count = referenceCount(for: image.relativePath)
            if count == 0 {
                candidates.append(CleanupCandidate(
                    id: image.relativePath, path: image.relativePath, kind: .image,
                    lastModified: image.lastModified, referenceCount: count))
            }
        }

        return candidates.sorted { $0.path < $1.path }
    }

    /// Recursively collects files under `dir` in sorted order, skipping excluded directories and
    /// symlinks. Missing `dir` → empty. Mirrors `ContentScanner.walk`/`SiteKnowledgeIndex.walk`.
    private static func walk(_ dir: URL) -> [URL] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: []
        ) else { return [] }
        var files: [URL] = []
        for entry in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let name = entry.lastPathComponent
            let values = try? entry.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            if values?.isSymbolicLink == true { continue }
            if values?.isDirectory == true {
                if excludedDirNames.contains(name) { continue }
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

    private static func mtime(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
            ?? Date(timeIntervalSince1970: 0)
    }

    private static func fileSize(_ url: URL) -> Int64? {
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize else { return nil }
        return Int64(size)
    }
}
