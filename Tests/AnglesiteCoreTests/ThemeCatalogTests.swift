import Foundation
import Testing
@testable import AnglesiteCore

struct ThemeCatalogTests {

    // A trimmed fixture mirroring the real themes.json shape (two themes, varied fonts).
    private let fixture = Data("""
    [
      {
        "id": "classic",
        "displayName": "Classic",
        "description": "Traditional, trustworthy, professional",
        "bestFor": ["legal", "finance"],
        "vars": {
          "color-primary": "#1e3a5f",
          "color-accent": "#c8a951",
          "font-heading": "Georgia, 'Times New Roman', serif",
          "font-body": "system-ui, -apple-system, sans-serif"
        }
      },
      {
        "id": "studio",
        "displayName": "Studio",
        "description": "Dark mode for creative coders",
        "bestFor": ["generative-art"],
        "vars": {
          "color-primary": "#00ff88",
          "color-accent": "#00ff88",
          "font-heading": "monospace",
          "font-body": "monospace"
        }
      }
    ]
    """.utf8)

    @Test func parsesThemesInOrder() throws {
        let themes = try ThemeCatalog.parse(themesJSON: fixture)
        #expect(themes.map(\.id) == ["classic", "studio"])
        #expect(themes[0].name == "Classic")
        #expect(themes[0].blurb == "Traditional, trustworthy, professional")
        #expect(themes[0].cssVars["color-primary"] == "#1e3a5f")
        // Font value with embedded commas + single quotes survives intact.
        #expect(themes[0].cssVars["font-heading"] == "Georgia, 'Times New Roman', serif")
        #expect(themes[0].swatch == ["#1e3a5f", "#c8a951"])
    }

    @Test func malformedJSONThrows() {
        #expect(throws: (any Error).self) {
            try ThemeCatalog.parse(themesJSON: Data("not json".utf8))
        }
    }

    @Test func defaultThemeIDResolvesForEverySiteType() throws {
        let catalog = ThemeCatalog(themes: try ThemeCatalog.parse(themesJSON: fixture))
        for type in SiteType.allCases {
            let id = catalog.defaultThemeID(for: type)
            #expect(catalog.theme(id: id) != nil, "no theme for \(type)")
        }
    }

    @Test func defaultThemeIDUsesPreferredMappingWhenPresent() {
        let ids = ["classic", "elegant", "warm", "bold", "community"]
        let catalog = ThemeCatalog(themes: ids.map {
            Theme(id: $0, name: $0, blurb: "", swatch: [], cssVars: [:])
        })
        #expect(catalog.defaultThemeID(for: .business) == "classic")
        #expect(catalog.defaultThemeID(for: .personal) == "elegant")
        #expect(catalog.defaultThemeID(for: .blog) == "warm")
        #expect(catalog.defaultThemeID(for: .portfolio) == "bold")
        #expect(catalog.defaultThemeID(for: .organization) == "community")
    }

    // DRIFT GUARD: decode the REAL bundled themes.json from the in-repo template.
    @Test func realThemesFileParsesToEightCompleteThemes() throws {
        let themes = try ThemeCatalog.parse(themesJSON: Data(contentsOf: Self.realThemesURL()))
        #expect(themes.count == 8, "expected 8 built-in themes")
        // A duplicate id would silently collide in theme(id:)'s first{} lookup (and in the
        // template's Object.fromEntries) — enforce uniqueness at the source.
        let ids = themes.map(\.id)
        #expect(Set(ids).count == ids.count, "duplicate theme id in themes.json: \(ids)")
        for theme in themes {
            for key in ["color-primary", "color-accent", "font-heading", "font-body"] {
                #expect(theme.cssVars[key] != nil, "\(theme.id) missing --\(key)")
            }
        }
        let catalog = ThemeCatalog(themes: themes)
        for type in SiteType.allCases {
            #expect(catalog.theme(id: catalog.defaultThemeID(for: type)) != nil)
        }
    }

    /// Resolve the real themes.json from the in-repo template (Resources/Template/).
    static func realThemesURL() -> URL {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return repoRoot.appendingPathComponent("Resources/Template/scripts/themes.json")
    }
}
