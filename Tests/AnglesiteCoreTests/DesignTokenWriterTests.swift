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

    @Test func rationaleIncludesSurfaceFoundationPairingAndAdjustSection() {
        let config = DesignConfigGenerator.config(axes: DesignAxesCatalog.balanced, siteType: "bakery", brandColor: nil)
        let md = DesignTokenWriter.rationaleMarkdown(for: config)

        #expect(md.contains("These five axes position your design. Each is a value from 0 to 1."))

        #expect(md.contains(config.palette.surface))
        #expect(md.contains("set a cool foundation."))

        let expectedPairing = config.typography.pairing
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "+", with: " + ")
        #expect(md.contains("Pairing strategy: \(expectedPairing)."))

        #expect(md.contains("## To adjust"))
        #expect(md.contains("Want it warmer? Increase `temperature` above"))
        #expect(md.contains("Want more authority? Increase `register` above"))
        #expect(md.contains("Want more whitespace? Decrease `weight` below"))
        #expect(md.contains("Want it more modern? Increase `time` above"))
        #expect(md.contains("Want it louder? Increase `voice` above"))
        #expect(md.contains("Anglesite will regenerate these tokens the next time you apply a design."))

        #expect(md.contains("Temperature (cool ↔ warm)"))
        #expect(md.contains("Weight (airy ↔ dense)"))
        #expect(md.contains("Register (playful ↔ authoritative)"))
        #expect(md.contains("Time (classic ↔ contemporary)"))
        #expect(md.contains("Voice (subtle ↔ bold)"))
        #expect(!md.contains("<->"))
    }

    @Test func rationaleUsesHighAxisWordingForHighValueAxes() {
        let axes = DesignAxes(temperature: 0.7, weight: 0.65, register: 0.8, time: 0.65, voice: 0.65)
        let config = DesignConfigGenerator.config(axes: axes, siteType: "bakery", brandColor: nil)
        let md = DesignTokenWriter.rationaleMarkdown(for: config)

        #expect(md.contains("warm"))
        #expect(md.contains("authoritative"))
        #expect(md.contains("conveys authority and expertise"))
        #expect(!md.contains("feels approachable and friendly"))
        #expect(md.contains("set a warm foundation."))
    }
}
