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

        let existing = Set(lines[..<closing]
            .filter { $0.trimmingCharacters(in: .whitespaces).hasPrefix("- ") }
            .map { $0.trimmingCharacters(in: .whitespaces).dropFirst(2).trimmingCharacters(in: .whitespaces) })
        let toAdd = newURLs.filter { !existing.contains($0) }
        guard !toAdd.isEmpty else { return contents }

        if let keyIndex = lines[..<closing].firstIndex(where: {
            $0.trimmingCharacters(in: .whitespaces) == "syndication:" || $0.hasPrefix("syndication:")
        }) {
            // Append after the last item of the existing list.
            var insertAt = keyIndex + 1
            while insertAt < closing, lines[insertAt].trimmingCharacters(in: .whitespaces).hasPrefix("- ") {
                insertAt += 1
            }
            lines.insert(contentsOf: toAdd.map { "  - \($0)" }, at: insertAt)
        } else {
            lines.insert(contentsOf: ["syndication:"] + toAdd.map { "  - \($0)" }, at: closing)
        }
        return lines.joined(separator: "\n")
    }
}
