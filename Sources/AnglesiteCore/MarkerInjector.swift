import Foundation

public enum MarkerInjector {
    public enum Failure: Error, Equatable { case anchorNotFound(String) }

    /// Delimiter syntax: `.html` for Astro template bodies (`<!-- … -->`), `.line` for Astro
    /// frontmatter / TypeScript (`// …`).
    public enum CommentStyle: Sendable, Equatable { case html, line }

    /// Inserts `snippet` (wrapped in `anglesite:<id>-<anchorSlug>:start/end` delimiters in the
    /// given `style`) immediately before the `atAnchor` comment; the anchor is preserved.
    /// Idempotent: an existing delimited block is replaced in place. Lone orphan markers are
    /// stripped before insertion.
    ///
    /// The anchor is folded into the delimiter (not just `id`+`style`) so a single descriptor can
    /// safely inject at two different anchors with the same style — e.g. a `<head>` anchor and a
    /// body-end anchor both using `.html` — without the second inject's markers colliding with
    /// and overwriting the first's content in place. See #472 review.
    public static func inject(snippet: String, withID id: String, atAnchor anchor: String,
                              into content: String, style: CommentStyle = .html) -> Result<String, Failure> {
        let key = "\(id)-\(anchorSlug(anchor))"
        let (start, end): (String, String)
        switch style {
        case .html: (start, end) = ("<!-- anglesite:\(key):start -->", "<!-- anglesite:\(key):end -->")
        case .line: (start, end) = ("// anglesite:\(key):start", "// anglesite:\(key):end")
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

    /// A short, stable slug derived from an anchor comment, e.g. "body-end" from
    /// "<!-- anglesite:body-end -->" or "imports" from "// anglesite:imports". Anchors that don't
    /// follow the "anglesite:<slug>" convention fall back to a sanitized version of the whole
    /// string, so the delimiter is always well-formed.
    private static func anchorSlug(_ anchor: String) -> String {
        guard let range = anchor.range(of: "anglesite:") else {
            let sanitized = anchor.filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
            return sanitized.isEmpty ? "anchor" : sanitized
        }
        let rest = anchor[range.upperBound...]
        let slug = rest.prefix { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
        return slug.isEmpty ? "anchor" : String(slug)
    }
}
