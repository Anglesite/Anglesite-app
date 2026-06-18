import XCTest
@testable import AnglesiteCore

final class ThemeCatalogTests: XCTestCase {

    // A trimmed fixture mirroring the real themes.ts shape (two themes, varied fonts).
    private let fixture = """
    export const THEMES: Record<string, Theme> = {
      classic: {
        displayName: "Classic",
        description: "Traditional, trustworthy, professional",
        bestFor: ["legal", "finance"],
        vars: {
          "color-primary": "#1e3a5f",
          "color-accent": "#c8a951",
          "font-heading": "Georgia, 'Times New Roman', serif",
          "font-body": "system-ui, -apple-system, sans-serif",
        },
      },
      studio: {
        displayName: "Studio",
        description: "Dark mode for creative coders",
        bestFor: ["generative-art"],
        vars: {
          "color-primary": "#00ff88",
          "color-accent": "#00ff88",
          "font-heading": "monospace",
          "font-body": "monospace",
        },
      },
    };
    """

    func testParsesThemesInOrder() throws {
        let themes = try ThemeCatalog.parse(themesTS: fixture)
        XCTAssertEqual(themes.map(\.id), ["classic", "studio"])
        XCTAssertEqual(themes[0].name, "Classic")
        XCTAssertEqual(themes[0].blurb, "Traditional, trustworthy, professional")
        XCTAssertEqual(themes[0].cssVars["color-primary"], "#1e3a5f")
        // Font value with embedded commas + single quotes survives intact.
        XCTAssertEqual(themes[0].cssVars["font-heading"], "Georgia, 'Times New Roman', serif")
        XCTAssertEqual(themes[0].swatch, ["#1e3a5f", "#c8a951"])
    }

    func testDefaultThemeIDResolvesForEverySiteType() throws {
        let catalog = ThemeCatalog(themes: try ThemeCatalog.parse(themesTS: fixture))
        for type in SiteType.allCases {
            let id = catalog.defaultThemeID(for: type)
            XCTAssertNotNil(catalog.theme(id: id), "no theme for \(type)")
        }
    }

    func testDefaultThemeIDUsesPreferredMappingWhenPresent() {
        let ids = ["classic", "elegant", "warm", "bold", "community"]
        let catalog = ThemeCatalog(themes: ids.map {
            Theme(id: $0, name: $0, blurb: "", swatch: [], cssVars: [:])
        })
        XCTAssertEqual(catalog.defaultThemeID(for: .business), "classic")
        XCTAssertEqual(catalog.defaultThemeID(for: .personal), "elegant")
        XCTAssertEqual(catalog.defaultThemeID(for: .blog), "warm")
        XCTAssertEqual(catalog.defaultThemeID(for: .portfolio), "bold")
        XCTAssertEqual(catalog.defaultThemeID(for: .organization), "community")
    }

    // DRIFT GUARD: parse the REAL bundled themes.ts from the in-repo template.
    func testRealThemesFileParsesToEightCompleteThemes() throws {
        let url = Self.realThemesURL()
        let ts = try String(contentsOf: url, encoding: .utf8)
        let themes = try ThemeCatalog.parse(themesTS: ts)
        XCTAssertEqual(themes.count, 8, "expected 8 built-in themes")
        for t in themes {
            for key in ["color-primary", "color-accent", "font-heading", "font-body"] {
                XCTAssertNotNil(t.cssVars[key], "\(t.id) missing --\(key)")
            }
        }
        let catalog = ThemeCatalog(themes: themes)
        for type in SiteType.allCases {
            XCTAssertNotNil(catalog.theme(id: catalog.defaultThemeID(for: type)))
        }
    }

    /// Resolve the real themes.ts from the in-repo template (Resources/Template/).
    static func realThemesURL() -> URL {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return repoRoot.appendingPathComponent("Resources/Template/scripts/themes.ts")
    }
}
