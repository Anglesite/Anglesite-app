import Foundation

/// Resolves a project-relative file path to its content type, so the app can open typed files in
/// the form editor. Collection entries are matched by their `src/content/<collection>/` directory;
/// page-stored singletons by a fixed path map. Pure, no I/O.
public enum ContentTypeResolver {
    /// Canonical singleton page paths for `.page`-stored types. `businessProfile` is shipped in the
    /// template at `src/pages/about.md` (this PR; the editor-relevant slice of #388).
    static let pagePaths: [String: String] = ["businessProfile": "src/pages/about.md"]

    public static func descriptor(
        forRelativePath path: String,
        registry: ContentTypeRegistry = ContentTypeRegistry()
    ) -> ContentTypeDescriptor? {
        let normalized = normalize(path)

        // 1. Collection entry by directory.
        let parts = normalized.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        if parts.count >= 4, parts[0] == "src", parts[1] == "content" {
            let collection = parts[2]
            if let match = registry.all.first(where: { $0.collection == collection }) { return match }
        }

        // 2. Page singleton by exact path.
        for (id, pagePath) in pagePaths where normalized == pagePath {
            return registry.descriptor(id: id)
        }
        return nil
    }

    private static func normalize(_ path: String) -> String {
        var p = path.replacingOccurrences(of: "\\", with: "/")
        while p.hasPrefix("./") { p.removeFirst(2) }
        while p.hasPrefix("/") { p.removeFirst() }
        return p
    }
}
