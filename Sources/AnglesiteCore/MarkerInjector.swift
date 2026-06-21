import Foundation

public enum MarkerInjector {
    public enum Failure: Error, Equatable { case anchorNotFound(String) }

    /// Delimiter syntax: `.html` for Astro template bodies (`<!-- … -->`), `.line` for Astro
    /// frontmatter / TypeScript (`// …`).
    public enum CommentStyle: Sendable, Equatable { case html, line }

    /// Inserts `snippet` (wrapped in `anglesite:<id>:start/end` delimiters in the given `style`)
    /// immediately before the `atAnchor` comment; the anchor is preserved. Idempotent: an existing
    /// delimited block is replaced in place. Lone orphan markers are stripped before insertion.
    public static func inject(snippet: String, withID id: String, atAnchor anchor: String,
                              into content: String, style: CommentStyle = .html) -> Result<String, Failure> {
        let (start, end): (String, String)
        switch style {
        case .html: (start, end) = ("<!-- anglesite:\(id):start -->", "<!-- anglesite:\(id):end -->")
        case .line: (start, end) = ("// anglesite:\(id):start", "// anglesite:\(id):end")
        }
        let block = "\(start)\n\(snippet)\n\(end)"

        if let r = content.range(of: start), let e = content.range(of: end), r.lowerBound < e.lowerBound {
            return .success(content.replacingCharacters(in: r.lowerBound..<e.upperBound, with: block))
        }
        guard content.range(of: anchor) != nil else { return .failure(.anchorNotFound(anchor)) }
        let stripped = content
            .components(separatedBy: "\n")
            .filter { $0.trimmingCharacters(in: .whitespaces) != start && $0.trimmingCharacters(in: .whitespaces) != end }
            .joined(separator: "\n")
        guard let a2 = stripped.range(of: anchor) else { return .failure(.anchorNotFound(anchor)) }
        return .success(stripped.replacingCharacters(in: a2.lowerBound..<a2.lowerBound, with: "\(block)\n"))
    }
}
