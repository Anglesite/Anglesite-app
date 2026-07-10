import Testing
@testable import AnglesiteCore

@Suite struct DesignTokenWriterTests {
    @Test func mapsConfigToExactlyTheTemplateTwelveVars() {
        let config = DesignConfigGenerator.config(axes: DesignAxesCatalog.balanced, siteType: "bakery", brandColor: nil)
        let vars = DesignTokenWriter.templateCSSVars(for: config)
        #expect(Set(vars.keys) == Set([
            "color-primary", "color-accent", "color-background", "color-surface",
            "color-text", "color-text-muted", "font-heading", "font-body",
            "spacing-unit", "radius-sm", "radius-md", "radius-lg",
        ]))
    }

    @Test func configColorPrimaryComesFromPaletteBrand() {
        let config = DesignConfigGenerator.config(axes: DesignAxesCatalog.balanced, siteType: "bakery", brandColor: "#ff0000")
        let vars = DesignTokenWriter.templateCSSVars(for: config)
        #expect(vars["color-primary"] == "#ff0000")
    }

    @Test func themeVarsPassThroughUnchanged() {
        let theme = Theme(id: "warm", name: "Warm", blurb: "cozy", swatch: ["#111", "#222"],
                          cssVars: ["color-primary": "#111", "font-heading": "Georgia"])
        let vars = DesignTokenWriter.templateCSSVars(for: theme)
        #expect(vars["color-primary"] == "#111")
        #expect(vars["font-heading"] == "Georgia")
    }

    @Test func rationaleIncludesAllFiveAxesAndBothColors() {
        let config = DesignConfigGenerator.config(axes: DesignAxesCatalog.balanced, siteType: "bakery", brandColor: nil)
        let md = DesignTokenWriter.rationaleMarkdown(for: config)
        for axisName in ["Temperature", "Weight", "Register", "Time", "Voice"] {
            #expect(md.contains(axisName))
        }
        #expect(md.contains(config.palette.brand))
        #expect(md.contains(config.palette.accent))
    }
}
