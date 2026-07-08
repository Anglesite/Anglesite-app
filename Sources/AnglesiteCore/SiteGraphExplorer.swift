import Foundation

public enum SiteGraphNodeKind: String, Sendable, CaseIterable, Identifiable {
    case page
    case layout
    case component
    case collection
    case contentEntry
    case asset
    case style

    public var id: String { rawValue }
}

public enum SiteGraphEdgeKind: String, Sendable, CaseIterable, Identifiable {
    case imports
    case usesLayout
    case referencesAsset
    case contains

    public var id: String { rawValue }
}

public struct SiteGraphNode: Sendable, Equatable, Identifiable {
    public let id: String
    public let kind: SiteGraphNodeKind
    public let title: String
    public let detail: String?
    public let filePath: String?
    public let route: String?
    public let referencedByCount: Int

    public init(
        id: String,
        kind: SiteGraphNodeKind,
        title: String,
        detail: String?,
        filePath: String?,
        route: String?,
        referencedByCount: Int = 0
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.detail = detail
        self.filePath = filePath
        self.route = route
        self.referencedByCount = referencedByCount
    }
}

public struct SiteGraphEdge: Sendable, Equatable, Identifiable {
    public let id: String
    public let sourceID: String
    public let targetID: String
    public let kind: SiteGraphEdgeKind

    public init(sourceID: String, targetID: String, kind: SiteGraphEdgeKind) {
        self.sourceID = sourceID
        self.targetID = targetID
        self.kind = kind
        self.id = "\(sourceID)->\(targetID):\(kind.rawValue)"
    }
}

public struct SiteGraphExplorerSnapshot: Sendable, Equatable {
    public let nodes: [SiteGraphNode]
    public let edges: [SiteGraphEdge]

    public init(nodes: [SiteGraphNode], edges: [SiteGraphEdge]) {
        self.nodes = nodes
        self.edges = edges
    }
}

public enum SiteGraphExplorer {
    private static let sourceExtensions: Set<String> = [
        ".astro", ".md", ".mdx", ".markdown", ".js", ".jsx", ".ts", ".tsx", ".css"
    ]
    private static let assetExtensions: Set<String> = [
        ".jpg", ".jpeg", ".png", ".webp", ".gif", ".svg", ".avif"
    ]
    private static let dynamicImportRegex = try! NSRegularExpression(
        pattern: #"import\(\s*['"]([^'"]+)['"]\s*\)"#
    )
    private static let srcHrefRegex = try! NSRegularExpression(
        pattern: #"\b(?:src|href)\s*=\s*["']([^"']+\.(?:jpg|jpeg|png|webp|gif|svg|avif))["']"#,
        options: [.caseInsensitive]
    )
    private static let urlAssetRegex = try! NSRegularExpression(
        pattern: #"url\(\s*['"]?([^'")]+\.(?:jpg|jpeg|png|webp|gif|svg|avif))['"]?\s*\)"#,
        options: [.caseInsensitive]
    )

    public static func build(
        projectRoot: URL,
        siteID: String,
        pages: [SiteContentGraph.Page],
        posts: [SiteContentGraph.Post],
        images: [SiteContentGraph.Image],
        fileManager: FileManager = .default
    ) -> SiteGraphExplorerSnapshot {
        var nodesByID: [String: SiteGraphNode] = [:]
        var edgesByID: [String: SiteGraphEdge] = [:]
        var nodeIDByRelativePath: [String: String] = [:]
        var nodeIDByPublicPath: [String: String] = [:]

        func addNode(_ node: SiteGraphNode) {
            nodesByID[node.id] = node
            if let filePath = node.filePath {
                nodeIDByRelativePath[filePath] = node.id
                if filePath.hasPrefix("public/") {
                    nodeIDByPublicPath["/" + String(filePath.dropFirst("public".count + 1))] = node.id
                }
            }
        }

        for page in pages {
            addNode(SiteGraphNode(
                id: page.id,
                kind: .page,
                title: page.title ?? page.route,
                detail: page.route,
                filePath: page.filePath,
                route: page.route
            ))
        }

        let collections = Dictionary(grouping: posts, by: \.collection)
        for collection in collections.keys.sorted() {
            let collectionID = "\(siteID):collection:\(collection)"
            addNode(SiteGraphNode(
                id: collectionID,
                kind: .collection,
                title: collection,
                detail: "src/content/\(collection)",
                filePath: nil,
                route: nil
            ))
        }
        for post in posts {
            let edge = SiteGraphEdge(
                sourceID: "\(siteID):collection:\(post.collection)",
                targetID: post.id,
                kind: .contains
            )
            addNode(SiteGraphNode(
                id: post.id,
                kind: .contentEntry,
                title: post.title,
                detail: "\(post.collection)/\(post.slug)",
                filePath: post.filePath,
                route: postRoute(for: post)
            ))
            edgesByID[edge.id] = edge
        }

        for image in images {
            addNode(SiteGraphNode(
                id: image.id,
                kind: .asset,
                title: image.fileName,
                detail: image.relativePath,
                filePath: image.relativePath,
                route: nil
            ))
        }

        for file in walk(projectRoot, fileManager: fileManager) {
            let relativePath = relativePosix(file, from: projectRoot)
            guard nodesByID[nodeIDByRelativePath[relativePath] ?? ""] == nil else { continue }
            let ext = fileExtension(file)
            let nodeKind: SiteGraphNodeKind?
            if sourceExtensions.contains(ext) {
                nodeKind = kind(for: relativePath)
            } else if assetExtensions.contains(ext) {
                nodeKind = .asset
            } else {
                nodeKind = nil
            }
            guard let kind = nodeKind else { continue }
            addNode(SiteGraphNode(
                id: "\(siteID):file:\(relativePath)",
                kind: kind,
                title: file.lastPathComponent,
                detail: relativePath,
                filePath: relativePath,
                route: nil
            ))
        }

        let sourceNodes = nodesByID.values
            .filter { $0.filePath != nil && $0.kind != .asset && $0.kind != .collection }
        for node in sourceNodes {
            guard let filePath = node.filePath else { continue }
            let fileURL = projectRoot.appendingPathComponent(filePath)
            guard let text = try? String(contentsOf: fileURL, encoding: .utf8) else { continue }
            for specifier in importSpecifiers(in: text) {
                guard let targetID = resolveImport(
                    specifier,
                    from: filePath,
                    projectRoot: projectRoot,
                    nodeIDByRelativePath: nodeIDByRelativePath,
                    nodeIDByPublicPath: nodeIDByPublicPath,
                    fileManager: fileManager
                ) else { continue }
                let targetKind = nodesByID[targetID]?.kind
                let edgeKind: SiteGraphEdgeKind
                if targetKind == .layout {
                    edgeKind = .usesLayout
                } else if targetKind == .asset {
                    edgeKind = .referencesAsset
                } else {
                    edgeKind = .imports
                }
                let edge = SiteGraphEdge(sourceID: node.id, targetID: targetID, kind: edgeKind)
                edgesByID[edge.id] = edge
            }
            for assetPath in assetReferences(in: text) {
                guard let targetID = resolveAssetReference(
                    assetPath,
                    from: filePath,
                    nodeIDByRelativePath: nodeIDByRelativePath,
                    nodeIDByPublicPath: nodeIDByPublicPath
                ) else { continue }
                let edge = SiteGraphEdge(sourceID: node.id, targetID: targetID, kind: .referencesAsset)
                edgesByID[edge.id] = edge
            }
        }

        let incomingCounts = Dictionary(grouping: edgesByID.values, by: \.targetID)
            .mapValues(\.count)
        let nodes = nodesByID.values.map { node in
            SiteGraphNode(
                id: node.id,
                kind: node.kind,
                title: node.title,
                detail: node.detail,
                filePath: node.filePath,
                route: node.route,
                referencedByCount: incomingCounts[node.id, default: 0]
            )
        }
        return SiteGraphExplorerSnapshot(
            nodes: nodes.sorted { lhs, rhs in
                if lhs.kind == rhs.kind { return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending }
                return kindRank(lhs.kind) < kindRank(rhs.kind)
            },
            edges: edgesByID.values.sorted { $0.id < $1.id }
        )
    }

    private static func kindRank(_ kind: SiteGraphNodeKind) -> Int {
        SiteGraphNodeKind.allCases.firstIndex(of: kind) ?? Int.max
    }

    private static func kind(for relativePath: String) -> SiteGraphNodeKind? {
        if relativePath.hasPrefix("src/layouts/") { return .layout }
        if relativePath.hasPrefix("src/components/") { return .component }
        if relativePath.hasPrefix("src/styles/") { return .style }
        return nil
    }

    private static func importSpecifiers(in text: String) -> [String] {
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        let staticImports = text.split(separator: "\n").compactMap(staticImportSpecifier)
        let dynamicImports = dynamicImportRegex.matches(in: text, range: range).compactMap { match in
            Range(match.range(at: 1), in: text).map { String(text[$0]) }
        }
        return staticImports + dynamicImports
    }

    private static func staticImportSpecifier(in line: Substring) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("import ") || trimmed.hasPrefix("export ") else { return nil }
        let searchStart: String.SubSequence
        if let fromRange = trimmed.range(of: " from ") {
            searchStart = trimmed[fromRange.upperBound...]
        } else {
            searchStart = trimmed[trimmed.startIndex...]
        }
        guard let quote = searchStart.first(where: { $0 == "\"" || $0 == "'" }) else { return nil }
        guard let open = searchStart.firstIndex(of: quote) else { return nil }
        let afterOpen = searchStart.index(after: open)
        guard let close = searchStart[afterOpen...].firstIndex(of: quote) else { return nil }
        return String(searchStart[afterOpen..<close])
    }

    private static func assetReferences(in text: String) -> [String] {
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        let regexes = [srcHrefRegex, urlAssetRegex]
        return regexes.flatMap { regex in
            regex.matches(in: text, range: range).compactMap { match in
                guard let found = Range(match.range(at: 1), in: text) else { return nil }
                let value = String(text[found])
                if value.hasPrefix("/") { return value }
                if value.hasPrefix("public/") { return "/" + String(value.dropFirst("public".count + 1)) }
                return value
            }
        }
    }

    private static func resolveAssetReference(
        _ value: String,
        from relativePath: String,
        nodeIDByRelativePath: [String: String],
        nodeIDByPublicPath: [String: String]
    ) -> String? {
        if value.hasPrefix("/") {
            return nodeIDByPublicPath[value]
        }
        if value.hasPrefix("public/") {
            return nodeIDByPublicPath["/" + String(value.dropFirst("public".count + 1))]
        }
        if value.hasPrefix("./") || value.hasPrefix("../") {
            let base = (relativePath as NSString).deletingLastPathComponent
            return nodeIDByRelativePath[normalizeRelativePath((base as NSString).appendingPathComponent(value))]
        }
        return nil
    }

    private static func resolveImport(
        _ specifier: String,
        from relativePath: String,
        projectRoot: URL,
        nodeIDByRelativePath: [String: String],
        nodeIDByPublicPath: [String: String],
        fileManager: FileManager
    ) -> String? {
        if specifier.hasPrefix("/") {
            return nodeIDByPublicPath[specifier]
        }
        var candidate: String
        if specifier.hasPrefix("@/") {
            candidate = "src/" + String(specifier.dropFirst(2))
        } else if specifier.hasPrefix("./") || specifier.hasPrefix("../") {
            let base = (relativePath as NSString).deletingLastPathComponent
            candidate = normalizeRelativePath((base as NSString).appendingPathComponent(specifier))
        } else {
            return nil
        }
        for path in candidatePaths(candidate, projectRoot: projectRoot, fileManager: fileManager) {
            if let id = nodeIDByRelativePath[path] { return id }
        }
        return nil
    }

    private static func normalizeRelativePath(_ path: String) -> String {
        var output: [String] = []
        for component in path.split(separator: "/", omittingEmptySubsequences: false) {
            switch component {
            case "", ".":
                continue
            case "..":
                if !output.isEmpty { output.removeLast() }
            default:
                output.append(String(component))
            }
        }
        return output.joined(separator: "/")
    }

    private static func candidatePaths(
        _ path: String,
        projectRoot: URL,
        fileManager: FileManager
    ) -> [String] {
        if !fileExtension(path).isEmpty { return [path] }
        let extensions = [".astro", ".md", ".mdx", ".js", ".jsx", ".ts", ".tsx", ".css"]
        var candidates = extensions.map { path + $0 }
        candidates += extensions.map { path + "/index" + $0 }
        return candidates.filter {
            fileManager.fileExists(atPath: projectRoot.appendingPathComponent($0).path(percentEncoded: false))
        }
    }

    private static func walk(_ dir: URL, fileManager: FileManager) -> [URL] {
        guard let enumerator = fileManager.enumerator(
            at: dir,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        var files: [URL] = []
        for case let url as URL in enumerator {
            let name = url.lastPathComponent
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            if values?.isSymbolicLink == true { continue }
            if values?.isDirectory == true {
                if ["node_modules", "dist", ".astro", ".git"].contains(name) {
                    enumerator.skipDescendants()
                }
                continue
            }
            files.append(url)
        }
        return files
    }

    private static func relativePosix(_ url: URL, from base: URL) -> String {
        let urlComponents = url.standardizedFileURL.pathComponents
        let baseComponents = base.standardizedFileURL.pathComponents
        guard urlComponents.starts(with: baseComponents) else { return url.path }
        return urlComponents.dropFirst(baseComponents.count).joined(separator: "/")
    }

    private static func fileExtension(_ path: String) -> String {
        let ext = (path as NSString).pathExtension
        return ext.isEmpty ? "" : "." + ext.lowercased()
    }

    private static func fileExtension(_ url: URL) -> String {
        fileExtension(url.path)
    }
}
