import Foundation

/// One built-in visual theme, decoded from `Resources/Template/scripts/themes.json`.
public struct Theme: Sendable, Identifiable, Equatable {
    public let id: String                    // theme id, e.g. "warm"
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

    public func theme(id: String) -> Theme? { themes.first { $0.id == id } }

    /// App-side default theme per broad site type. Falls back to the first available theme
    /// if the preferred id isn't present (keeps the drift guard meaningful).
    public func defaultThemeID(for type: SiteType) -> String {
        let preferred: [SiteType: String] = [
            .business: "classic", .personal: "elegant", .blog: "warm",
            .portfolio: "bold", .organization: "community", .blank: "classic",
        ]
        let want = preferred[type] ?? "classic"
        if theme(id: want) != nil { return want }
        return themes.first?.id ?? want
    }

    /// Load the bundled template's theme catalog. `templateURL` is the template root
    /// (`TemplateRuntime.resolve().url`); the data lives at scripts/themes.json — the same
    /// file the template's `scripts/themes.ts` imports, so both sides share one source of truth.
    public static func load(templateURL: URL) throws -> ThemeCatalog {
        let url = templateURL.appendingPathComponent("scripts/themes.json")
        return ThemeCatalog(themes: try parse(themesJSON: Data(contentsOf: url)))
    }

    /// The shared catalog is an ordered JSON array of theme records; decoding preserves
    /// the array order (the first entry is the fallback default theme).
    public static func parse(themesJSON data: Data) throws -> [Theme] {
        struct Record: Decodable {
            let id: String
            let displayName: String
            let description: String
            let bestFor: [String]
            let vars: [String: String]
        }
        return try JSONDecoder().decode([Record].self, from: data).map { record in
            Theme(
                id: record.id,
                name: record.displayName,
                blurb: record.description,
                swatch: ["color-primary", "color-accent"].compactMap { record.vars[$0] },
                cssVars: record.vars
            )
        }
    }
}
