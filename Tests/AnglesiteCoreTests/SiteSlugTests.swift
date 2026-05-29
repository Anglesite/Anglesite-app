import XCTest
@testable import AnglesiteCore

final class SiteSlugTests: XCTestCase {
    func testLowercasesAndHyphenates() {
        XCTAssertEqual(SiteSlug.derive(from: "Blue Bottle Cafe"), "blue-bottle-cafe")
    }
    func testStripsPunctuationAndCollapsesHyphens() {
        XCTAssertEqual(SiteSlug.derive(from: "  Hello!!   World  "), "hello-world")
    }
    func testFoldsDiacritics() {
        XCTAssertEqual(SiteSlug.derive(from: "Café Niño"), "cafe-nino")
    }
    func testEmptyFallsBackToUntitled() {
        XCTAssertEqual(SiteSlug.derive(from: "   "), "untitled-site")
    }
    func testDraftDefaultsHeadlineFromName() {
        let d = NewSiteDraft(siteType: .business, name: "Acme")
        XCTAssertEqual(d.headline, "Acme")
        XCTAssertEqual(d.themeID, "")
    }
}
