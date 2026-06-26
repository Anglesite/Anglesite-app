// Sources/AnglesiteCore/ContentScaffold.swift
import Foundation

/// Pure, side-effect-free scaffolding for new pages and posts. Byte-faithful to the Node
/// sidecar's `create-content.mjs` so switching the create backend produces no git churn.
public enum ContentScaffold {

    /// lowercase → NFKD → strip combining marks → drop `'` and `"` → non-alphanumerics to `-` → trim `-`.
    public static func slugify(_ value: String) -> String {
        let lowered = value.lowercased()
        let decomposed = lowered.decomposedStringWithCompatibilityMapping // NFKD
        let stripped = String(decomposed.unicodeScalars.filter { !(0x0300...0x036F ~= $0.value) })
        let noQuotes = stripped
            .replacingOccurrences(of: "'", with: "")
            .replacingOccurrences(of: "\"", with: "")
        let hyphenated = noQuotes.replacingOccurrences(
            of: "[^a-z0-9]+", with: "-", options: .regularExpression)
        return hyphenated.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    /// Slugify each `/`-separated segment, drop empties, rejoin with a leading slash.
    public static func normalizeRoute(_ route: String) -> String {
        let segments = route
            .split(separator: "/", omittingEmptySubsequences: false)
            .map { slugify(String($0)) }
            .filter { !$0.isEmpty }
        return "/" + segments.joined(separator: "/")
    }

    public static func pageRelativePath(normalizedRoute: String) -> String {
        "src/pages" + normalizedRoute + ".astro"
    }

    public static func postRelativePath(collection: String, slug: String) -> String {
        "src/content/\(collection)/\(slug).md"
    }

    /// `/about` → `../layouts/BaseLayout.astro`; `/a/b` → `../../layouts/BaseLayout.astro`.
    public static func layoutImport(normalizedRoute: String) -> String {
        let trimmed = normalizedRoute.hasPrefix("/") ? String(normalizedRoute.dropFirst()) : normalizedRoute
        let depth = trimmed.split(separator: "/", omittingEmptySubsequences: false).count
        return String(repeating: "../", count: depth) + "layouts/BaseLayout.astro"
    }

    public static func renderPage(title: String, layoutImport: String) -> String {
        let description = "\(title)."
        return """
        ---
        import BaseLayout from "\(layoutImport)";
        ---

        <BaseLayout title="\(escapeAttr(title))" description="\(escapeAttr(description))">
          <main>
            <h1>\(escapeHTML(title))</h1>
            <p>Add your content here.</p>
          </main>
        </BaseLayout>
        """ + "\n"
    }

    public static func renderPost(title: String, now: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let publishDate = formatter.string(from: now)
        return """
        ---
        title: "\(escapeYAML(title))"
        description: ""
        publishDate: \(publishDate)
        draft: true
        tags: []
        ---

        Write your post here.
        """ + "\n"
    }

    /// Render a new content entry's file contents from its descriptor: a YAML frontmatter block
    /// (one line per non-markdown field, in declaration order) followed by a placeholder body for
    /// the type's `markdown` field, if any. Pure; mirrors `renderPost`'s ISO8601 date format.
    public static func renderEntry(descriptor: ContentTypeDescriptor, title: String?, now: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let dateTime = formatter.string(from: now)

        var lines: [String] = ["---"]
        var bodyPlaceholder: String?
        for field in descriptor.fields {
            switch field.kind {
            case .markdown:
                bodyPlaceholder = "Write your \(descriptor.displayName.lowercased()) here."
            case .datetime:
                lines.append("\(field.name): \(dateTime)")
            case .date:
                lines.append("\(field.name): \(String(dateTime.prefix(10)))")
            case .bool:
                lines.append("\(field.name): false")
            case .number:
                lines.append("\(field.name): 0")
            case .stringArray, .imageArray:
                lines.append("\(field.name): []")
            case .string, .text, .url, .image:
                let value = (field.name == "title" || field.name == "name") ? (title ?? "") : ""
                lines.append("\(field.name): \"\(escapeYAML(value))\"")
            }
        }
        lines.append("---")

        var output = lines.joined(separator: "\n") + "\n"
        if let bodyPlaceholder {
            output += "\n\(bodyPlaceholder)\n"
        }
        return output
    }

    // MARK: - Escaping (order matters: `&` first)

    static func escapeAttr(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
         .replacingOccurrences(of: "\"", with: "&quot;")
    }

    static func escapeHTML(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
         .replacingOccurrences(of: "<", with: "&lt;")
         .replacingOccurrences(of: ">", with: "&gt;")
    }

    static func escapeYAML(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
         .replacingOccurrences(of: "\"", with: "\\\"")
    }
}
