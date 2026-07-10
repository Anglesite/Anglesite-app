import Testing
@testable import AnglesiteCore

struct CSSColorTests {
    @Test("parses 6-digit hex") func sixDigit() {
        #expect(CSSColor.parse("#ff0000") != nil)
    }

    @Test("parses 3-digit hex") func threeDigit() {
        #expect(CSSColor.parse("#f00") != nil)
    }

    @Test("returns nil for named colors") func namedColorFallsBack() {
        #expect(CSSColor.parse("red") == nil)
    }

    @Test("format round-trips a parsed hex color") func roundTrip() {
        let color = CSSColor.parse("#3366ff")!
        #expect(CSSColor.format(color) == "#3366ff")
    }

    @Test("format preserves alpha as 8-digit hex") func roundTripWithAlpha() {
        let color = CSSColor.parse("#3366ff80")!
        #expect(CSSColor.format(color) == "#3366ff80")
    }

    @Test("color property set includes the common properties") func propertySet() {
        #expect(CSSColor.colorProperties.contains("background-color"))
        #expect(!CSSColor.colorProperties.contains("padding"))
    }
}
