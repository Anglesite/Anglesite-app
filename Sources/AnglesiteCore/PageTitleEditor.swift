import Foundation

/// Rewrites a page/post's *title* in place — frontmatter `title:` for markdown-family files,
/// the first `title="…"`/`title='…'` attribute for `.astro`/`.html`. Pure and I/O-free so the
/// transform is fully unit-testable; `NavigatorRenameService` owns the disk + git side.
///
/// `.astro` files use a JavaScript component script between `---` fences (NOT YAML), so we never
/// write YAML frontmatter there — the title lives in the layout invocation's `title=` prop.
public enum PageTitleEditor {
    public enum RewriteError: Error, Equatable {
        case emptyTitle
        case noEditableLocation
    }

    private static let markdownExts: Set<String> = ["md", "mdx", "mdoc", "markdown"]
    private static let attributeExts: Set<String> = ["astro", "html"]

    public static func rewrite(
        contents: String,
        fileExtension: String,
        newTitle: String
    ) -> Result<String, RewriteError> {
        let trimmed = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .failure(.emptyTitle) }

        let ext = fileExtension.lowercased()
        if markdownExts.contains(ext) { return .success(rewriteMarkdown(contents, title: trimmed)) }
        if attributeExts.contains(ext) { return rewriteAttribute(contents, title: trimmed) }
        // Unknown extension: nowhere defined to write a title.
        return .failure(.noEditableLocation)
    }

    // MARK: - Markdown frontmatter

    /// Replace the `title:` line inside a leading `---` block, insert one if the block lacks it,
    /// or synthesize a block at the top of the file.
    private static func rewriteMarkdown(_ contents: String, title: String) -> String {
        let yaml = "title: \(yamlQuoted(title))"

        // A frontmatter block must start at byte 0 with `---` on its own line.
        guard contents.hasPrefix("---\n") || contents == "---" || contents.hasPrefix("---\r\n") else {
            return "---\n\(yaml)\n---\n\n\(contents)"
        }

        // Normalize to \n for line work; the templates use \n.
        var lines = contents.components(separatedBy: "\n")
        // lines[0] == "---". Find the closing fence.
        guard let close = lines.dropFirst().firstIndex(of: "---") else {
            // Malformed (no closing fence) — treat as no frontmatter and prepend a fresh block.
            return "---\n\(yaml)\n---\n\n\(contents)"
        }

        // Look for an existing top-level `title:` between the fences.
        if let titleIdx = (1..<close).first(where: { lineKey(lines[$0]) == "title" }) {
            lines[titleIdx] = yaml
        } else {
            lines.insert(yaml, at: 1)
        }
        return lines.joined(separator: "\n")
    }

    /// The top-level key of a frontmatter line (`title: "x"` → `title`), or nil for indented /
    /// keyless lines. Mirrors `Frontmatter`'s "top-level keys only" rule.
    private static func lineKey(_ line: String) -> String? {
        guard let first = line.first, first != " ", first != "\t" else { return nil }
        guard let colon = line.firstIndex(of: ":") else { return nil }
        return String(line[line.startIndex..<colon]).trimmingCharacters(in: .whitespaces)
    }

    /// Double-quote a YAML scalar, escaping `\` then `"`.
    private static func yamlQuoted(_ s: String) -> String {
        let escaped = s.replacingOccurrences(of: "\\", with: "\\\\")
                       .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    // MARK: - Attribute (astro / html)

    /// Port of `ContentScanner.titleAttrRegex` — the first `title="…"` or `title='…'`.
    private static let titleAttrRegex = try! NSRegularExpression(
        pattern: #"\btitle\s*=\s*(?:"([^"]*)"|'([^']*)')"#
    )

    private static func rewriteAttribute(_ contents: String, title: String) -> Result<String, RewriteError> {
        let full = NSRange(contents.startIndex..<contents.endIndex, in: contents)
        guard let match = titleAttrRegex.firstMatch(in: contents, range: full) else {
            return .failure(.noEditableLocation)
        }
        // Which capture group matched tells us the delimiter: group 1 = ", group 2 = '.
        let usesDouble = match.range(at: 1).location != NSNotFound
        let delimiter: Character = usesDouble ? "\"" : "'"
        let replacement = "title=\(delimiter)\(attrEscaped(title, delimiter: delimiter))\(delimiter)"
        guard let whole = Range(match.range, in: contents) else { return .failure(.noEditableLocation) }
        return .success(contents.replacingCharacters(in: whole, with: replacement))
    }

    /// HTML-attribute-escape: always `&` and `<`/`>`, plus the active quote delimiter.
    private static func attrEscaped(_ s: String, delimiter: Character) -> String {
        var out = s.replacingOccurrences(of: "&", with: "&amp;")
                   .replacingOccurrences(of: "<", with: "&lt;")
                   .replacingOccurrences(of: ">", with: "&gt;")
        out = delimiter == "\""
            ? out.replacingOccurrences(of: "\"", with: "&quot;")
            : out.replacingOccurrences(of: "'", with: "&#39;")
        return out
    }
}
