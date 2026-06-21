import Foundation

/// A parsed frontmatter scalar/array value. Mirrors the `string | boolean | string[]` union the
/// Node `parseFrontmatter` returns — the distinction matters to the scanner (`draft === true`
/// wants a real boolean; `Array.isArray(tags)` wants a real array).
public enum FrontmatterValue: Equatable, Sendable {
    case string(String)
    case bool(Bool)
    case array([String])
}

/// Native port of `server/content-frontmatter.mjs` (Bucket 1, #275).
///
/// A deliberately minimal YAML reader for the handful of fields `list_content` needs off
/// article-like collection entries (`title`, `slug`, `draft`, `publishDate`, `date`, `tags`).
/// It parses exactly that subset — quoted/unquoted scalars, booleans, and string arrays in both
/// inline (`[a, b]`) and block (`- a`) form, top-level keys only — and leaves anything it doesn't
/// recognize out of the returned map rather than guessing.
public enum Frontmatter {
    /// Parse the leading `---` frontmatter block of `source`. Returns an empty map when there is
    /// no frontmatter at the very start of the file.
    public static func parse(_ source: String) -> [String: FrontmatterValue] {
        guard let block = frontmatterBlock(source) else { return [:] }

        var out: [String: FrontmatterValue] = [:]
        // Split on `\n` and `\r\n` (the Node parser's `/\r?\n/`) by normalizing CRLF first.
        let lines = block.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var i = 0
        while i < lines.count {
            let line = lines[i]
            defer { i += 1 }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            // Only top-level keys (no leading whitespace) start a new field.
            if let first = line.first, first == " " || first == "\t" { continue }

            guard let (key, rawValue) = splitKeyValue(line) else { continue }

            if rawValue.isEmpty {
                // Possible block array on the following indented `- item` lines.
                var items: [String] = []
                var j = i + 1
                while j < lines.count, let item = blockArrayItem(lines[j]) {
                    items.append(unquote(item))
                    j += 1
                }
                if !items.isEmpty {
                    out[key] = .array(items)
                    i = j - 1
                } else {
                    out[key] = .string("")
                }
                continue
            }

            out[key] = parseScalarOrArray(rawValue)
        }
        return out
    }

    // MARK: - Helpers

    /// Extract the text between the opening `---<newline>` and the first following `<newline>---`,
    /// anchored at the very start of `source`. `nil` if there is no such block.
    private static func frontmatterBlock(_ source: String) -> String? {
        let pattern = try! NSRegularExpression(pattern: "^---\\r?\\n([\\s\\S]*?)\\r?\\n---")
        let range = NSRange(source.startIndex..<source.endIndex, in: source)
        guard let match = pattern.firstMatch(in: source, range: range),
              let captured = Range(match.range(at: 1), in: source)
        else { return nil }
        return String(source[captured])
    }

    /// Split `key: value` where key is `[A-Za-z0-9_-]+`. Value is right-trimmed of surrounding
    /// whitespace (`\s*(.*)` in the Node regex, then `.trim()`).
    private static func splitKeyValue(_ line: String) -> (key: String, value: String)? {
        guard let colon = line.firstIndex(of: ":") else { return nil }
        let key = String(line[line.startIndex..<colon])
        guard !key.isEmpty, key.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }) else {
            return nil
        }
        let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
        return (key, value)
    }

    /// If `line` is a block-array item (`^\s*-\s+item`), return its trimmed item text.
    private static func blockArrayItem(_ line: String) -> String? {
        let stripped = String(line.drop(while: { $0 == " " || $0 == "\t" }))
        guard stripped.hasPrefix("-") else { return nil }
        let afterDash = stripped.dropFirst()
        // Require at least one whitespace after the dash (the `\s+` in `-\s+`).
        guard let firstAfter = afterDash.first, firstAfter == " " || firstAfter == "\t" else { return nil }
        return String(afterDash).trimmingCharacters(in: .whitespaces)
    }

    private static func parseScalarOrArray(_ raw: String) -> FrontmatterValue {
        if raw == "true" { return .bool(true) }
        if raw == "false" { return .bool(false) }
        if raw.hasPrefix("["), raw.hasSuffix("]") {
            let inner = String(raw.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
            if inner.isEmpty { return .array([]) }
            // `omittingEmptySubsequences: false` matches JS `String.split(",")`, which keeps empties.
            return .array(
                inner.split(separator: ",", omittingEmptySubsequences: false)
                    .map { unquote($0.trimmingCharacters(in: .whitespaces)) }
            )
        }
        return .string(unquote(raw))
    }

    /// Strip a single layer of matching `"` or `'` quotes, else return as-is.
    private static func unquote(_ s: String) -> String {
        if s.count >= 2,
           (s.hasPrefix("\"") && s.hasSuffix("\"")) || (s.hasPrefix("'") && s.hasSuffix("'")) {
            return String(s.dropFirst().dropLast())
        }
        return s
    }
}
