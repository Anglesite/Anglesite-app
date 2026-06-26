// Sources/AnglesiteCore/ContentScaffold.swift
import Foundation

/// Pure, side-effect-free scaffolding for new pages and posts. Byte-faithful to the Node
/// sidecar's `create-content.mjs` so switching the create backend produces no git churn.
public enum ContentScaffold {
    public struct PageTemplate: Sendable, Equatable, Hashable, Identifiable {
        public let id: String
        public let displayName: String

        public init(id: String, displayName: String) {
            self.id = id
            self.displayName = displayName
        }

        public static let standard = PageTemplate(id: "standard", displayName: "Standard Page")
        public static let landing = PageTemplate(id: "landing", displayName: "Landing Page")
        public static let contact = PageTemplate(id: "contact", displayName: "Contact Page")

        public static let builtIns: [PageTemplate] = [.standard, .landing, .contact]
    }

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

    public static func renderPage(
        title: String,
        layoutImport: String,
        template: PageTemplate = .standard
    ) -> String {
        let description = "\(title)."
        let body: String
        switch template.id {
        case PageTemplate.landing.id:
            body = """
              <main>
                <section>
                  <p>Welcome</p>
                  <h1>\(escapeHTML(title))</h1>
                  <p>Add a short promise for this page.</p>
                </section>
                <section>
                  <h2>Highlights</h2>
                  <ul>
                    <li>First thing visitors should know.</li>
                    <li>Second thing visitors should know.</li>
                    <li>Next step visitors can take.</li>
                  </ul>
                </section>
              </main>
            """
        case PageTemplate.contact.id:
            body = """
              <main>
                <h1>\(escapeHTML(title))</h1>
                <p>Tell visitors how to reach you.</p>
                <address>
                  <a href="mailto:hello@example.com">hello@example.com</a>
                </address>
              </main>
            """
        default:
            body = """
              <main>
                <h1>\(escapeHTML(title))</h1>
                <p>Add your content here.</p>
              </main>
            """
        }
        return """
        ---
        import BaseLayout from "\(layoutImport)";
        ---

        <BaseLayout title="\(escapeAttr(title))" description="\(escapeAttr(description))">
        \(body)
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

    public static func renderCollectionEntry(
        title: String,
        descriptor: ContentTypeDescriptor,
        now: Date
    ) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let publishDate = formatter.string(from: now)
        var frontmatter: [String] = []
        var bodyFieldName: String?

        let fieldNames = Set(descriptor.fields.map(\.name))
        if fieldNames.contains("title") {
            frontmatter.append(#"title: "\#(escapeYAML(title))""#)
        } else if fieldNames.contains("name") {
            frontmatter.append(#"name: "\#(escapeYAML(title))""#)
            frontmatter.append(#"title: "\#(escapeYAML(title))""#)
        } else if fieldNames.contains("itemReviewed") {
            frontmatter.append(#"itemReviewed: "\#(escapeYAML(title))""#)
            frontmatter.append(#"title: "\#(escapeYAML(title))""#)
        } else {
            frontmatter.append(#"title: "\#(escapeYAML(title))""#)
        }

        for field in descriptor.fields {
            if frontmatter.contains(where: { $0.hasPrefix(field.name + ":") }) { continue }
            switch field.kind {
            case .markdown:
                bodyFieldName = bodyFieldName ?? field.name
            case .datetime:
                frontmatter.append("\(field.name): \(publishDate)")
            case .date:
                frontmatter.append("\(field.name): \(String(publishDate.prefix(10)))")
            case .bool:
                frontmatter.append("\(field.name): false")
            case .number:
                frontmatter.append("\(field.name): 0")
            case .stringArray:
                frontmatter.append("\(field.name): []")
            case .string, .text, .url, .image:
                frontmatter.append(#"\#(field.name): """#)
            }
        }

        if !fieldNames.contains("draft") {
            frontmatter.append("draft: true")
        }

        let body = bodyFieldName.map { "Write your \($0) here." } ?? "Write your entry here."
        return """
        ---
        \(frontmatter.joined(separator: "\n"))
        ---

        \(body)
        """ + "\n"
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
