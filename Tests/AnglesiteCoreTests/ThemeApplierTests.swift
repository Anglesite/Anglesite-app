import XCTest
@testable import AnglesiteCore

final class ThemeApplierTests: XCTestCase {
    private let css = """
    :root {
      --color-primary: #2563eb;
      --color-accent: #d97706;
      --font-heading: system-ui, -apple-system, sans-serif;
      --font-body: system-ui, -apple-system, sans-serif;
      --space-md: 1rem;
      --radius-sm: 4px;
    }
    """
    private let theme = Theme(
        id: "warm", name: "Warm", blurb: "",
        swatch: [],
        cssVars: [
            "color-primary": "#e65100",
            "color-accent": "#c62828",
            "font-heading": "Georgia, 'Times New Roman', serif",
            "font-body": "system-ui, sans-serif",
        ]
    )

    func testReplacesProvidedPropertiesOnly() {
        let out = ThemeApplier.apply(theme, toCSS: css)
        XCTAssertTrue(out.contains("--color-primary: #e65100;"))
        XCTAssertTrue(out.contains("--color-accent: #c62828;"))
        XCTAssertTrue(out.contains("--font-heading: Georgia, 'Times New Roman', serif;"))
        // Untouched, no matching cssVars key:
        XCTAssertTrue(out.contains("--space-md: 1rem;"))
        XCTAssertTrue(out.contains("--radius-sm: 4px;"))
    }

    func testIsIdempotent() {
        let once = ThemeApplier.apply(theme, toCSS: css)
        let twice = ThemeApplier.apply(theme, toCSS: once)
        XCTAssertEqual(once, twice)
    }

    func testWritesFileInPlace() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let cssPath = dir.appendingPathComponent("src/styles/global.css")
        try FileManager.default.createDirectory(at: cssPath.deletingLastPathComponent(), withIntermediateDirectories: true)
        try css.write(to: cssPath, atomically: true, encoding: .utf8)
        try ThemeApplier.apply(theme, siteDirectory: dir)
        let out = try String(contentsOf: cssPath, encoding: .utf8)
        XCTAssertTrue(out.contains("--color-primary: #e65100;"))
    }

    func testValueContainingDollarAndBackslash() {
        let theme = Theme(id: "t", name: "", blurb: "", swatch: [],
                          cssVars: ["color-primary": #"url($1\path)"#])
        let css = ":root { --color-primary: #fff; }"
        let out = ThemeApplier.apply(theme, toCSS: css)
        XCTAssertTrue(out.contains(#"--color-primary: url($1\path);"#))
    }
}
