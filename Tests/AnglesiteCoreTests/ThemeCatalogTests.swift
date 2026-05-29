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

    // DRIFT GUARD: parse the REAL bundled plugin themes.ts. Skips when the sibling
    // plugin checkout isn't present (e.g. CI without it / pure `swift test`).
    func testRealThemesFileParsesToEightCompleteThemes() throws {
        guard let url = Self.realThemesURL(), let ts = try? String(contentsOf: url, encoding: .utf8) else {
            throw XCTSkip("plugin themes.ts not found; set ANGLESITE_PLUGIN_PATH or check out ../anglesite")
        }
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

    /// Resolve the real themes.ts via env override or the sibling repo relative to this source file.
    static func realThemesURL() -> URL? {
        let fm = FileManager.default
        if let env = ProcessInfo.processInfo.environment["ANGLESITE_PLUGIN_PATH"] {
            let u = URL(fileURLWithPath: env)
                .appendingPathComponent("template/scripts/themes.ts")
            if fm.fileExists(atPath: u.path) { return u }
        }
        // <repo>/Tests/AnglesiteCoreTests/ThemeCatalogTests.swift -> repo root is 3 up.
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let sibling = repoRoot.deletingLastPathComponent()
            .appendingPathComponent("anglesite/template/scripts/themes.ts")
        return fm.fileExists(atPath: sibling.path) ? sibling : nil
    }
}
