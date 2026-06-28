
/// A page's editable metadata. Phase 1 covers title + description; the rendered `<title>` is
/// composed from a site-level tokenized template (main site settings, out of scope here) with this
/// per-page `title` substituted.
public struct PageMetadata: Equatable, Sendable {
    public var title: String
    public var description: String
    public init(title: String, description: String) {
        self.title = title
        self.description = description
    }
}

/// Reads/writes `title` + `description` frontmatter for plain (non-typed) frontmatter pages.
/// Goes through `FrontmatterDocument`, so unknown keys and the body survive verbatim and only a
/// changed key is re-rendered. Pure, no I/O.
public enum PageMetadataEditor {
    public static func read(_ contents: String) -> PageMetadata {
        let doc = FrontmatterDocument.parse(contents)
        return PageMetadata(title: scalar(doc, "title"), description: scalar(doc, "description"))
    }

    public static func write(_ metadata: PageMetadata, into contents: String) -> String {
        var doc = FrontmatterDocument.parse(contents)
        let current = read(contents)
        if metadata.title != current.title { doc.set(.string(metadata.title), for: "title") }
        if metadata.description != current.description {
            doc.set(.string(metadata.description), for: "description")
        }
        return doc.serialized()
    }

    private static func scalar(_ doc: FrontmatterDocument, _ key: String) -> String {
        if case .string(let s)? = doc.value(for: key) { return s }
        return ""
    }
}
