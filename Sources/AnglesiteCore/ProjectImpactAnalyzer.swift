import Foundation

/// Best-effort, read-only impact analysis for a proposed project edit.
///
/// This intentionally does not try to be a full Astro compiler. It builds a conservative
/// dependency graph from static relative imports and public image references, then maps the
/// affected source files back to known routes/content entries.
public enum ProjectImpactAnalyzer {
    public struct Report: Sendable, Equatable {
        public let targetPath: String
        public let affectedPages: [AffectedPage]
        public let directImporters: [String]
        public let layoutImporters: [String]
        public let referencedImages: [String]
        public let contentCollections: [String]

        public var affectedPageCount: Int { affectedPages.count }

        public init(
            targetPath: String,
            affectedPages: [AffectedPage],
            directImporters: [String],
            layoutImporters: [String],
            referencedImages: [String],
            contentCollections: [String]
        ) {
            self.targetPath = targetPath
            self.affectedPages = affectedPages
            self.directImporters = directImporters
            self.layoutImporters = layoutImporters
            self.referencedImages = referencedImages
            self.contentCollections = contentCollections
        }

        public var isEmpty: Bool {
            affectedPages.isEmpty
                && directImporters.isEmpty
                && layoutImporters.isEmpty
                && referencedImages.isEmpty
                && contentCollections.isEmpty
        }
    }

    public struct AffectedPage: Sendable, Equatable {
        public let route: String
        public let title: String?
        public let filePath: String

        public init(route: String, title: String?, filePath: String) {
            self.route = route
            self.title = title
            self.filePath = filePath
        }

        public var displayName: String { title?.isEmpty == false ? title! : route }
    }

    private struct SourceFile {
        let path: String
        let url: URL
        let text: String
    }

    private static let sourceExtensions: Set<String> = [
        "astro", "md", "mdx", "mdoc", "markdown", "html",
        "js", "jsx", "ts", "tsx", "mjs", "cjs",
        "css", "scss", "sass", "json"
    ]
    private static let imageExtensions: Set<String> = ["jpg", "jpeg", "png", "webp", "gif", "svg", "avif"]
    private static let resolvableExtensions = [
        "astro", "md", "mdx", "mdoc", "markdown", "html",
        "ts", "tsx", "js", "jsx", "mjs", "cjs",
        "css", "json"
    ]

    private static let importRegexes: [NSRegularExpression] = [
        try! NSRegularExpression(pattern: #"\bimport\s+(?:[^'"]+\s+from\s+)?['"]([^'"]+)['"]"#),
        try! NSRegularExpression(pattern: #"\bexport\s+[^'"]+\s+from\s+['"]([^'"]+)['"]"#),
        try! NSRegularExpression(pattern: #"\bimport\s*\(\s*['"]([^'"]+)['"]\s*\)"#),
        try! NSRegularExpression(pattern: #"@import\s+(?:url\()?['"]?([^'")\s]+)"#)
    ]
    private static let imageReferenceRegex = try! NSRegularExpression(
        pattern: #"(?:"|')(/images/[^"']+\.(?:jpg|jpeg|png|webp|gif|svg|avif))(?:"|')"#,
        options: [.caseInsensitive]
    )

    public static func analyze(
        projectRoot: URL,
        siteID: String,
        changedPath: String,
        graph: SiteContentGraph? = nil
    ) async -> Report? {
        let root = projectRoot.standardizedFileURL
        let files = sourceFiles(in: root)
        let knownPaths = Set(files.map(\.path))
        var pages: [SiteContentGraph.Page] = []
        var posts: [SiteContentGraph.Post] = []
        var images: [SiteContentGraph.Image] = []
        if let graph {
            pages = await graph.pages(for: siteID)
            posts = await graph.posts(for: siteID)
            images = await graph.images(for: siteID)
        }
        if pages.isEmpty && posts.isEmpty && images.isEmpty {
            let listing = ContentScanner.scan(projectRoot: root, siteID: siteID)
            pages = listing.pages
            posts = listing.posts
            images = listing.images
        }

        guard let target = resolveChangedPath(changedPath, pages: pages, knownPaths: knownPaths) else {
            return nil
        }

        let importsByFile = Dictionary(uniqueKeysWithValues: files.map { file in
            (file.path, resolvedImports(in: file, root: root, knownPaths: knownPaths))
        })
        let directImporters = importsByFile
            .filter { $0.value.contains(target) }
            .map(\.key)
            .sorted()

        let reverse = reverseIndex(importsByFile)
        let affectedFiles = transitiveImporters(of: target, reverse: reverse).union([target])
        let affectedPageFiles = Set(pages.map(\.filePath)).intersection(affectedFiles)
        let affectedPages = pages
            .filter { affectedPageFiles.contains($0.filePath) }
            .sorted { normalizedRoute($0.route) < normalizedRoute($1.route) }
            .map { AffectedPage(route: $0.route, title: $0.title, filePath: $0.filePath) }

        let layoutImporters = directImporters
            .filter { $0.hasPrefix("src/layouts/") || $0.contains("/layouts/") }
            .sorted()

        let contentCollections = Set(posts.compactMap { post -> String? in
            affectedFiles.contains(post.filePath) ? post.collection : nil
        }).sorted()

        let referencedImages = imageReferences(
            target: target,
            files: files,
            affectedFiles: affectedFiles,
            knownImages: images.map(\.relativePath)
        )

        return Report(
            targetPath: target,
            affectedPages: affectedPages,
            directImporters: directImporters,
            layoutImporters: layoutImporters,
            referencedImages: referencedImages,
            contentCollections: contentCollections
        )
    }

    public static func confirmationSummary(for report: Report?, routeLimit: Int = 5) -> String? {
        guard let report, !report.isEmpty else { return nil }
        var parts: [String] = []
        if report.affectedPageCount == 1 {
            parts.append("This change may affect 1 page")
        } else if report.affectedPageCount > 1 {
            parts.append("This change may affect \(report.affectedPageCount) pages")
        }
        if !report.directImporters.isEmpty {
            parts.append("imported by \(report.directImporters.count) file\(report.directImporters.count == 1 ? "" : "s")")
        }
        if !report.layoutImporters.isEmpty {
            parts.append("including \(report.layoutImporters.count) layout\(report.layoutImporters.count == 1 ? "" : "s")")
        }
        if !report.referencedImages.isEmpty {
            parts.append("references \(report.referencedImages.count) image\(report.referencedImages.count == 1 ? "" : "s")")
        }
        if !report.contentCollections.isEmpty {
            parts.append("included in \(report.contentCollections.count) content collection\(report.contentCollections.count == 1 ? "" : "s")")
        }
        guard !parts.isEmpty else { return nil }

        let routes = report.affectedPages.prefix(routeLimit).map(\.displayName)
        var summary = parts.joined(separator: "; ") + "."
        if !routes.isEmpty {
            summary += " Affected routes: " + routes.joined(separator: ", ")
            if report.affectedPages.count > routeLimit {
                summary += ", and \(report.affectedPages.count - routeLimit) more"
            }
            summary += "."
        }
        return summary
    }

    private static func sourceFiles(in root: URL) -> [SourceFile] {
        walk(root)
            .filter { sourceExtensions.contains($0.pathExtension.lowercased()) }
            .compactMap { url in
                guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
                return SourceFile(path: relativePosix(url, from: root), url: url, text: text)
            }
            .sorted { $0.path < $1.path }
    }

    private static func walk(_ dir: URL) -> [URL] {
        let skippedDirectories = Set([".git", ".astro", "node_modules", "dist", ".vercel", ".netlify"])
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
        ) else { return [] }
        var files: [URL] = []
        for entry in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let isDir = (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if isDir == true {
                if skippedDirectories.contains(entry.lastPathComponent) { continue }
                files.append(contentsOf: walk(entry))
            } else {
                files.append(entry)
            }
        }
        return files
    }

    private static func resolvedImports(in file: SourceFile, root: URL, knownPaths: Set<String>) -> Set<String> {
        var out = Set<String>()
        for specifier in importSpecifiers(in: file.text) where specifier.hasPrefix(".") {
            if let resolved = resolveImport(specifier, from: file.url, root: root, knownPaths: knownPaths) {
                out.insert(resolved)
            }
        }
        return out
    }

    private static func importSpecifiers(in text: String) -> [String] {
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return importRegexes.flatMap { regex in
            regex.matches(in: text, range: range).compactMap { match in
                guard let r = Range(match.range(at: 1), in: text) else { return nil }
                return String(text[r])
            }
        }
    }

    private static func resolveImport(_ specifier: String, from fileURL: URL, root: URL, knownPaths: Set<String>) -> String? {
        let base = fileURL.deletingLastPathComponent().appendingPathComponent(specifier).standardizedFileURL
        let rel = relativePosix(base, from: root)
        if knownPaths.contains(rel) { return rel }
        if !base.pathExtension.isEmpty { return nil }
        for ext in resolvableExtensions {
            let candidate = rel + "." + ext
            if knownPaths.contains(candidate) { return candidate }
        }
        for ext in resolvableExtensions {
            let candidate = rel + "/index." + ext
            if knownPaths.contains(candidate) { return candidate }
        }
        return nil
    }

    private static func reverseIndex(_ importsByFile: [String: Set<String>]) -> [String: Set<String>] {
        var reverse: [String: Set<String>] = [:]
        for (importer, imports) in importsByFile {
            for imported in imports {
                reverse[imported, default: []].insert(importer)
            }
        }
        return reverse
    }

    private static func transitiveImporters(of target: String, reverse: [String: Set<String>]) -> Set<String> {
        var seen = Set<String>()
        var stack = Array(reverse[target] ?? [])
        while let next = stack.popLast() {
            if !seen.insert(next).inserted { continue }
            stack.append(contentsOf: reverse[next] ?? [])
        }
        return seen
    }

    private static func imageReferences(
        target: String,
        files: [SourceFile],
        affectedFiles: Set<String>,
        knownImages: [String]
    ) -> [String] {
        let targetIsImage = imageExtensions.contains(URL(fileURLWithPath: target).pathExtension.lowercased())
        if targetIsImage {
            return knownImages.contains(target) ? [target] : []
        }
        let fileByPath = Dictionary(uniqueKeysWithValues: files.map { ($0.path, $0) })
        let refs = affectedFiles.compactMap { fileByPath[$0]?.text }.flatMap(imageReferencePaths)
        return Array(Set(refs)).sorted()
    }

    private static func imageReferencePaths(in text: String) -> [String] {
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return imageReferenceRegex.matches(in: text, range: range).compactMap { match in
            guard let r = Range(match.range(at: 1), in: text) else { return nil }
            return "public" + String(text[r])
        }
    }

    private static func resolveChangedPath(_ changedPath: String, pages: [SiteContentGraph.Page], knownPaths: Set<String>) -> String? {
        let trimmed = changedPath.trimmingCharacters(in: .whitespacesAndNewlines)
        if knownPaths.contains(trimmed) { return trimmed }
        let withoutLeadingSlash = trimmed.hasPrefix("/") ? String(trimmed.dropFirst()) : trimmed
        if knownPaths.contains(withoutLeadingSlash) { return withoutLeadingSlash }
        let route = normalizedRoute(trimmed)
        if let page = pages.first(where: { normalizedRoute($0.route) == route }) {
            return page.filePath
        }
        return nil
    }

    private static func normalizedRoute(_ route: String) -> String {
        var value = route.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty { return "/" }
        if !value.hasPrefix("/") { value = "/" + value }
        while value.count > 1 && value.hasSuffix("/") { value.removeLast() }
        return value
    }

    private static func relativePosix(_ url: URL, from base: URL) -> String {
        let urlComponents = url.standardizedFileURL.pathComponents
        let baseComponents = base.standardizedFileURL.pathComponents
        guard urlComponents.starts(with: baseComponents) else { return url.path }
        return urlComponents.dropFirst(baseComponents.count).joined(separator: "/")
    }
}
