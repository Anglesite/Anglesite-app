import Testing
import Foundation
@testable import AnglesiteCore

@Suite("content.config.ts drift guard")
struct ContentConfigDriftTests {

    /// Repo-root-relative path to the committed template config. `swift test` runs with CWD = package root.
    static var configFile: URL {
        URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
            .appendingPathComponent("Resources/Template/src/content.config.ts")
    }

    /// Canonical Zod expression for a field kind, or nil for the markdown body (excluded from frontmatter).
    static func zod(for kind: ContentTypeField.Kind) -> String? {
        switch kind {
        case .markdown: return nil
        case .string, .text, .image: return "z.string()"
        case .url: return "z.string().url()"
        case .date, .datetime: return "z.coerce.date()"
        case .number: return "z.number()"
        case .bool: return "z.boolean()"
        case .stringArray, .imageArray: return "z.array(z.string())"
        }
    }

    /// The single canonical `defineCollection` block for a collection-backed descriptor.
    static func canonicalBlock(_ d: ContentTypeDescriptor) -> String? {
        guard let collection = d.collection else { return nil }
        var schemaLines: [String] = []
        for field in d.fields {
            guard let zod = zod(for: field.kind) else { continue }
            let expr = field.required ? zod : "\(zod).optional()"
            schemaLines.append("    \(field.name): \(expr),")
        }
        return """
        const \(collection) = defineCollection({
          loader: glob({ pattern: "**/*.md", base: "./src/content/\(collection)" }),
          schema: z.object({
        \(schemaLines.joined(separator: "\n"))
          }),
        });
        """
    }

    @Test("every collection-backed registry type appears verbatim in content.config.ts")
    func configMatchesRegistry() throws {
        let source = try String(contentsOf: Self.configFile, encoding: .utf8)
        let exportLine = source
            .split(separator: "\n", omittingEmptySubsequences: false)
            .first { $0.contains("export const collections") }
            .map(String.init) ?? ""

        // Scope to the canonical builtin vocabulary, not a registry instance: a custom type
        // registered elsewhere must not make this guard demand a block in the committed template.
        for descriptor in ContentTypeRegistry.builtIns {
            guard let collection = descriptor.collection,
                  let block = Self.canonicalBlock(descriptor) else { continue }
            #expect(source.contains(block),
                    "content.config.ts is missing or has drifted from the canonical block for `\(collection)`:\n\(block)")
            #expect(exportLine.contains(collection),
                    "`\(collection)` is not listed in the `collections` export")
        }
    }
}
