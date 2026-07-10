// Tests/AnglesiteCoreTests/DesignPaletteGeneratorTests.swift
import Testing
@testable import AnglesiteCore

@Suite struct DesignPaletteGeneratorTests {
    @Test func generatesAllSevenTokens() {
        let palette = DesignPaletteGenerator.generate(axes: DesignAxesCatalog.balanced, brandColor: nil)
        for hex in [palette.brand, palette.accent, palette.bg, palette.surface, palette.text, palette.muted, palette.border] {
            #expect(WCAGContrast.hexToRGB(hex) != nil)
        }
    }

    @Test func honorsExplicitBrandColor() {
        let palette = DesignPaletteGenerator.generate(axes: DesignAxesCatalog.balanced, brandColor: "#ff0000")
        #expect(palette.brand == "#ff0000")
    }

    @Test func ignoresInvalidBrandColorAndDerivesInstead() {
        let derived = DesignPaletteGenerator.generate(axes: DesignAxesCatalog.balanced, brandColor: "not-a-color")
        #expect(derived.brand != "not-a-color")
        #expect(WCAGContrast.hexToRGB(derived.brand) != nil)
    }

    @Test func textMeetsAAAgainstBackground() {
        let palette = DesignPaletteGenerator.generate(axes: DesignAxesCatalog.balanced, brandColor: nil)
        #expect(WCAGContrast.meetsAA(fg: palette.text, bg: palette.bg))
    }

    @Test func mutedMeetsAAAgainstBackground() {
        let palette = DesignPaletteGenerator.generate(axes: DesignAxesCatalog.balanced, brandColor: nil)
        #expect(WCAGContrast.meetsAA(fg: palette.muted, bg: palette.bg))
    }

    @Test func warmTemperatureProducesDifferentBrandHueThanCool() {
        let warm = DesignPaletteGenerator.generate(
            axes: DesignAxes(temperature: 1.0, weight: 0.4, register: 0.5, time: 0.5, voice: 0.4), brandColor: nil)
        let cool = DesignPaletteGenerator.generate(
            axes: DesignAxes(temperature: 0.0, weight: 0.4, register: 0.5, time: 0.5, voice: 0.4), brandColor: nil)
        #expect(warm.brand != cool.brand)
    }

    @Test func goldenValueForBalancedAxesWithNoBrandColor() {
        let palette = DesignPaletteGenerator.generate(axes: DesignAxesCatalog.balanced, brandColor: nil)
        #expect(palette.brand == "#269c75")
        #expect(palette.accent == "#2a98cf")
        #expect(palette.bg == "#f9fafa")
        #expect(palette.surface == "#f1f4f3")
        #expect(palette.text == "#19201e")
        #expect(palette.muted == "#6b7672")
        #expect(palette.border == "#d7e0dd")
    }

    @Test func goldenValueForDarkModeAxesWithNoBrandColor() {
        let palette = DesignPaletteGenerator.generate(
            axes: DesignAxes(temperature: 0.6, weight: 0.9, register: 0.5, time: 0.5, voice: 0.9),
            brandColor: nil)
        #expect(palette.brand == "#1fa33b")
        #expect(palette.accent == "#e033bb")
        #expect(palette.bg == "#171e18")
        #expect(palette.surface == "#202922")
        #expect(palette.text == "#eaecea")
        #expect(palette.muted == "#91a194")
        #expect(palette.border == "#2e3830")
    }
}
