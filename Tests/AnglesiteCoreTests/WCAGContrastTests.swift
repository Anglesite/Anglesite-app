import Testing
@testable import AnglesiteCore

@Suite struct WCAGContrastTests {
    @Test func hexToRGBParsesSixDigit() {
        #expect(WCAGContrast.hexToRGB("#2563eb") == RGBColor(r: 0x25, g: 0x63, b: 0xeb))
    }

    @Test func hexToRGBExpandsThreeDigit() {
        #expect(WCAGContrast.hexToRGB("#f00") == RGBColor(r: 0xff, g: 0x00, b: 0x00))
    }

    @Test func hexToRGBRejectsInvalid() {
        #expect(WCAGContrast.hexToRGB("not-a-color") == nil)
    }

    @Test func contrastRatioBlackOnWhiteIsMax() {
        let ratio = WCAGContrast.contrastRatio("#000000", "#ffffff")
        #expect(abs(ratio - 21.0) < 0.01)
    }

    @Test func contrastRatioIsOrderIndependent() {
        #expect(WCAGContrast.contrastRatio("#123456", "#abcdef") ==
                WCAGContrast.contrastRatio("#abcdef", "#123456"))
    }

    @Test func meetsAAThreshold() {
        #expect(WCAGContrast.meetsAA(fg: "#000000", bg: "#ffffff") == true)
        #expect(WCAGContrast.meetsAA(fg: "#777777", bg: "#888888") == false)
    }

    @Test func suggestReadableReturnsOriginalWhenAlreadyPassing() {
        #expect(WCAGContrast.suggestReadable(fg: "#000000", bg: "#ffffff") == "#000000")
    }

    @Test func suggestReadableDarkensOnLightBackground() {
        let fixed = WCAGContrast.suggestReadable(fg: "#aaaaaa", bg: "#ffffff")
        #expect(WCAGContrast.meetsAA(fg: fixed, bg: "#ffffff"))
    }

    @Test func suggestReadableLightensOnDarkBackground() {
        let fixed = WCAGContrast.suggestReadable(fg: "#333333", bg: "#000000")
        #expect(WCAGContrast.meetsAA(fg: fixed, bg: "#000000"))
    }
}
