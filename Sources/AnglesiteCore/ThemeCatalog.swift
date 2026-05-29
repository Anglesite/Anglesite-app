import Foundation

/// One built-in visual theme, parsed from the plugin's `template/scripts/themes.ts`.
public struct Theme: Sendable, Identifiable, Equatable {
    public let id: String                    // THEMES record key, e.g. "warm"
    public let name: String                  // displayName
    public let blurb: String                 // description
    public let swatch: [String]              // [color-primary, color-accent] for the gallery
    public let cssVars: [String: String]     // vars: custom-property name (no leading --) -> value

    public init(id: String, name: String, blurb: String, swatch: [String], cssVars: [String: String]) {
        self.id = id; self.name = name; self.blurb = blurb; self.swatch = swatch; self.cssVars = cssVars
    }
}

/// The 8 built-in themes plus the wizard's default-by-site-type mapping.
public struct ThemeCatalog: Sendable {
    public let themes: [Theme]
    public init(themes: [Theme]) { self.themes = themes }

    public enum ParseError: Error, Sendable, Equatable { case noThemesDeclaration }

    public func theme(id: String) -> Theme? { themes.first { $0.id == id } }

    /// App-side default theme per broad site type. Falls back to the first available theme
    /// if the preferred id isn't present (keeps the drift guard meaningful).
    public func defaultThemeID(for type: SiteType) -> String {
        let preferred: [SiteType: String] = [
            .business: "classic", .personal: "elegant", .blog: "warm",
            .portfolio: "bold", .organization: "community",
        ]
        let want = preferred[type] ?? "classic"
        if theme(id: want) != nil { return want }
        return themes.first?.id ?? want
    }

    /// Load + parse the bundled plugin's themes.ts. `pluginURL` is the plugin root
    /// (`PluginRuntime.resolve().url`); themes.ts lives at template/scripts/themes.ts.
    public static func load(pluginURL: URL) throws -> ThemeCatalog {
        let url = pluginURL.appendingPathComponent("template/scripts/themes.ts")
        let ts = try String(contentsOf: url, encoding: .utf8)
        return ThemeCatalog(themes: try parse(themesTS: ts))
    }

    /// Tolerant parser keyed on the known field order (displayName, description, bestFor, vars).
    public static func parse(themesTS: String) throws -> [Theme] {
        guard themesTS.contains("THEMES") else { throw ParseError.noThemesDeclaration }

        // Per-theme block: id, displayName, description, bestFor[...], vars{...}.
        // `vars` body uses [^}]* — safe because vars holds no nested braces.
        let themePattern = #"(\w+):\s*\{\s*displayName:\s*"([^"]*)",\s*description:\s*"([^"]*)",\s*bestFor:\s*\[[^\]]*\],\s*vars:\s*\{([^}]*)\}"#
        let varPattern = #""([^"]+)":\s*"([^"]*)""#

        let themeRE = try NSRegularExpression(pattern: themePattern, options: [.dotMatchesLineSeparators])
        let varRE = try NSRegularExpression(pattern: varPattern, options: [])

        let ns = themesTS as NSString
        var result: [Theme] = []
        for m in themeRE.matches(in: themesTS, range: NSRange(location: 0, length: ns.length)) {
            let id = ns.substring(with: m.range(at: 1))
            let name = ns.substring(with: m.range(at: 2))
            let blurb = ns.substring(with: m.range(at: 3))
            let varsBody = ns.substring(with: m.range(at: 4))

            var vars: [String: String] = [:]
            let vns = varsBody as NSString
            for vm in varRE.matches(in: varsBody, range: NSRange(location: 0, length: vns.length)) {
                vars[vns.substring(with: vm.range(at: 1))] = vns.substring(with: vm.range(at: 2))
            }
            let swatch = ["color-primary", "color-accent"].compactMap { vars[$0] }
            result.append(Theme(id: id, name: name, blurb: blurb, swatch: swatch, cssVars: vars))
        }
        return result
    }
}
