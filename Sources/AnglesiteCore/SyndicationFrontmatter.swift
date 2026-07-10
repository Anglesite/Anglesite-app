import Foundation

/// Deterministic POSSE trail (#465): records published-copy URLs in the post's `syndication:`
/// frontmatter list (the u-syndication source the mf2 layer projects). Pure string → string.
public enum SyndicationFrontmatter {
    public static func adding(urls: [String], to contents: String) -> String {
        let newURLs = urls.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !newURLs.isEmpty else { return contents }
        var lines = contents.components(separatedBy: "\n")

        // No frontmatter at all: synthesize a fence around the syndication block.
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---",
              let closing = lines.dropFirst().firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" })
        else {
            let block = ["---", "syndication:"] + newURLs.map { "  - \($0)" } + ["---"]
            return (block + [contents]).joined(separator: "\n")
        }

        guard let keyIndex = lines[..<closing].firstIndex(where: {
            $0.trimmingCharacters(in: .whitespaces) == "syndication:" || $0.hasPrefix("syndication:")
        }) else {
            // No syndication key yet: nothing to dedup against.
            lines.insert(contentsOf: ["syndication:"] + newURLs.map { "  - \($0)" }, at: closing)
            return lines.joined(separator: "\n")
        }

        if let inlineItems = inlineListItems(lines[keyIndex]) {
            // Inline form (`syndication: [a, b]`): dedup against the inline items,
            // then rewrite the line as block form with existing + new items.
            let toAdd = newURLs.filter { !inlineItems.contains($0) }
            guard !toAdd.isEmpty else { return contents }
            let blockLines = ["syndication:"] + (inlineItems + toAdd).map { "  - \($0)" }
            lines.replaceSubrange(keyIndex...keyIndex, with: blockLines)
            return lines.joined(separator: "\n")
        }

        // Block form: existing items are the consecutive "  - item" lines right after the key.
        var itemEnd = keyIndex + 1
        while itemEnd < closing, lines[itemEnd].trimmingCharacters(in: .whitespaces).hasPrefix("- ") {
            itemEnd += 1
        }
        let existing = Set(lines[(keyIndex + 1)..<itemEnd]
            .map { $0.trimmingCharacters(in: .whitespaces).dropFirst(2).trimmingCharacters(in: .whitespaces) })
        let toAdd = newURLs.filter { !existing.contains($0) }
        guard !toAdd.isEmpty else { return contents }
        lines.insert(contentsOf: toAdd.map { "  - \($0)" }, at: itemEnd)
        return lines.joined(separator: "\n")
    }

    /// Parses the inline array items of a `syndication: [a, b]` line.
    /// Returns `nil` for a bare `syndication:` key (block form, or empty).
    private static func inlineListItems(_ line: String) -> [String]? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("syndication:") else { return nil }
        let rest = trimmed.dropFirst("syndication:".count).trimmingCharacters(in: .whitespaces)
        guard rest.hasPrefix("[") else { return nil }
        var inner = rest
        if inner.hasSuffix("]") { inner.removeLast() }
        inner.removeFirst()
        let items = inner.split(separator: ",").map { item -> String in
            var value = item.trimmingCharacters(in: .whitespaces)
            if value.count >= 2,
               (value.hasPrefix("\"") && value.hasSuffix("\"")) || (value.hasPrefix("'") && value.hasSuffix("'")) {
                value.removeFirst()
                value.removeLast()
            }
            return value
        }
        return items.filter { !$0.isEmpty }
    }
}
