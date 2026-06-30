import Foundation
import AnglesiteSiteModel

/// Curated, group-oriented view of a site's filesystem-backed parts for the Site Navigator.
/// Pages/Posts are sourced from `SiteContentGraph`, not here — this scanner covers only the
/// Components, Styles, and Metadata groups.
///
/// Roots are resolved adaptively: an `.anglesite` package (#242) exposes `Source/` and `Config/`;
/// a plain directory (the current pre-package layout) is treated as the project root directly.
public enum FileGroup: String, Sendable, CaseIterable {
    case pages, posts, components, styles, metadata
}

public struct FileRef: Sendable, Equatable, Identifiable {
    public var id: String { url.path(percentEncoded: false) }
    public let url: URL
    public let group: FileGroup
    public let name: String

    public init(url: URL, group: FileGroup, name: String) {
        self.url = url
        self.group = group
        self.name = name
    }
}

public enum SiteFileTree {
    public struct Layout: Sendable, Equatable {
        public let sourceDir: URL
        public let configDir: URL?
        public let infoPlist: URL?
    }

    /// Directory names never descended into or listed.
    private static let excludedDirNames: Set<String> = ["node_modules", "dist", ".astro", ".git"]
    private static let excludedFileNames: Set<String> = [".DS_Store"]

    public static func layout(for siteRoot: URL, fileManager: FileManager = .default) -> Layout {
        if AnglesitePackage.isPackage(at: siteRoot, fileManager: fileManager) {
            let pkg = AnglesitePackage(url: siteRoot)
            return Layout(sourceDir: pkg.sourceURL, configDir: pkg.configURL, infoPlist: pkg.infoPlistURL)
        }
        return Layout(sourceDir: siteRoot, configDir: nil, infoPlist: nil)
    }

    public static func scan(siteRoot: URL, fileManager: FileManager = .default) -> [FileGroup: [FileRef]] {
        let layout = layout(for: siteRoot, fileManager: fileManager)
        var result: [FileGroup: [FileRef]] = [:]

        // Components: layouts + components dirs under src/.
        let componentDirs = ["src/layouts", "src/components"].map { layout.sourceDir.appendingPathComponent($0) }
        let components = componentDirs.flatMap { files(in: $0, group: .components, fileManager: fileManager) }
        if !components.isEmpty { result[.components] = components.sorted { $0.name < $1.name } }

        // Styles: src/styles.
        let styles = files(in: layout.sourceDir.appendingPathComponent("src/styles"),
                           group: .styles, fileManager: fileManager)
        if !styles.isEmpty { result[.styles] = styles.sorted { $0.name < $1.name } }

        // Metadata: everything in Config/ plus the package Info.plist marker.
        var metadata: [FileRef] = []
        if let configDir = layout.configDir {
            metadata += files(in: configDir, group: .metadata, fileManager: fileManager)
        }
        if let infoPlist = layout.infoPlist, fileManager.fileExists(atPath: infoPlist.path(percentEncoded: false)) {
            metadata.append(FileRef(url: infoPlist, group: .metadata, name: infoPlist.lastPathComponent))
        }
        if !metadata.isEmpty { result[.metadata] = metadata.sorted { $0.name < $1.name } }

        return result
    }

    /// Recursively lists files under `dir`, skipping excluded dirs/files. Returns [] if `dir` is absent.
    private static func files(in dir: URL, group: FileGroup, fileManager: FileManager) -> [FileRef] {
        guard let enumerator = fileManager.enumerator(
            at: dir,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var refs: [FileRef] = []
        for case let url as URL in enumerator {
            let name = url.lastPathComponent
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            // Skip symlinks entirely: the exclusion set only matches real directory names, so a
            // symlinked tree (e.g. pnpm's symlinked node_modules) would slip past it, and a symlink
            // cycle would loop forever. `skipDescendants()` only works on real directories.
            if values?.isSymbolicLink == true { continue }
            if values?.isDirectory == true {
                if excludedDirNames.contains(name) { enumerator.skipDescendants() }
                continue
            }
            if excludedFileNames.contains(name) { continue }
            refs.append(FileRef(url: url, group: group, name: name))
        }
        return refs
    }
}
