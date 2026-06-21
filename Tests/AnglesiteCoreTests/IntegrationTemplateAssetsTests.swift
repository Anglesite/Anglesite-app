// Tests/AnglesiteCoreTests/IntegrationTemplateAssetsTests.swift
// Hermetic test — no app bundle or TemplateRuntime needed.
// Resolves the template by walking up from #filePath:
//   .../Tests/AnglesiteCoreTests/IntegrationTemplateAssetsTests.swift
//   → deletingLastPathComponent x3 → repo root
//   → appending "Resources/Template"
import Testing
import Foundation
@testable import AnglesiteCore

@Suite struct IntegrationTemplateAssetsTests {

    private func templateRoot() -> URL {
        let here = URL(filePath: #filePath)
        // here      = .../Tests/AnglesiteCoreTests/IntegrationTemplateAssetsTests.swift
        // parent[0] = .../Tests/AnglesiteCoreTests/
        // parent[1] = .../Tests/
        // parent[2] = repo root
        let repoRoot = here
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return repoRoot.appending(path: "Resources/Template")
    }

    @Test func requiredAssetsExist() {
        let root = templateRoot()
        let paths = [
            "src/components/BookingWidget.astro",
            "src/components/DonationButton.astro",
            "src/components/Comments.astro",
            "src/pages/book.astro",
            "src/pages/donate.astro",
        ]
        for p in paths {
            #expect(
                FileManager.default.fileExists(atPath: root.appending(path: p).path(percentEncoded: false)),
                "missing \(p)"
            )
        }
    }

    // Collect all .writeConfig ConfigEntry keys from a descriptor's operations.
    private func writtenConfigKeys(for descriptor: IntegrationDescriptor) -> Set<String> {
        var keys = Set<String>()
        for op in descriptor.operations {
            if case .writeConfig(let entries, _) = op {
                for entry in entries { keys.insert(entry.key) }
            }
        }
        return keys
    }

    // Extract all import.meta.env.IDENTIFIER tokens from an Astro file.
    private func envKeysReferenced(in source: String) -> Set<String> {
        var keys = Set<String>()
        // Match import.meta.env.SOME_KEY (uppercase identifiers only — these are env vars)
        let pattern = #"import\.meta\.env\.([A-Z][A-Z0-9_]*)"#
        let regex = try! NSRegularExpression(pattern: pattern)
        let range = NSRange(source.startIndex..., in: source)
        for match in regex.matches(in: source, range: range) {
            if let keyRange = Range(match.range(at: 1), in: source) {
                keys.insert(String(source[keyRange]))
            }
        }
        return keys
    }

    /// Guard test: env keys referenced by each integration page must be a subset of the
    /// keys that its descriptor writes via .writeConfig operations.
    /// This catches mismatches like DONATIONS_LABEL (page) vs DONATIONS_BUTTON_TEXT (descriptor).
    @Test func pageEnvKeysAreWrittenByDescriptors() throws {
        let root = templateRoot()

        // Booking: src/pages/book.astro
        let bookURL = root.appending(path: "src/pages/book.astro")
        let bookSource = try String(contentsOf: bookURL, encoding: .utf8)
        let bookReferenced = envKeysReferenced(in: bookSource)
        let bookWritten = writtenConfigKeys(for: IntegrationCatalog.descriptor(for: .booking))
        let bookUnknown = bookReferenced.subtracting(bookWritten)
        #expect(bookUnknown.isEmpty,
            "book.astro references env keys not written by booking descriptor: \(bookUnknown.sorted())")

        // Donations: src/pages/donate.astro
        let donateURL = root.appending(path: "src/pages/donate.astro")
        let donateSource = try String(contentsOf: donateURL, encoding: .utf8)
        let donateReferenced = envKeysReferenced(in: donateSource)
        let donateWritten = writtenConfigKeys(for: IntegrationCatalog.descriptor(for: .donations))
        let donateUnknown = donateReferenced.subtracting(donateWritten)
        #expect(donateUnknown.isEmpty,
            "donate.astro references env keys not written by donations descriptor: \(donateUnknown.sorted())")
    }

    @Test func layoutsHaveAnchors() throws {
        let root = templateRoot()
        let baseURL = root.appending(path: "src/layouts/BaseLayout.astro")
        let base = try String(contentsOf: baseURL, encoding: .utf8)
        #expect(base.contains("<!-- anglesite:body-end -->"))

        let blogURL = root.appending(path: "src/layouts/BlogPost.astro")
        let blog = try String(contentsOf: blogURL, encoding: .utf8)
        #expect(blog.contains("<!-- anglesite:comments -->"))
    }
}
