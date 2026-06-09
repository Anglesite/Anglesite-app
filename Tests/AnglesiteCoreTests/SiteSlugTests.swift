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
    func testDigitsOnlyNameIsKept() {
        XCTAssertEqual(SiteSlug.derive(from: "42"), "42")
    }
    func testTransliteratedNameIsAsciiSlugAndNonEmpty() {
        // Accented / ligature names should transliterate to a clean ascii slug, not collapse to empty.
        let slug = SiteSlug.derive(from: "Æsop & Çödë")
        XCTAssertFalse(slug.isEmpty)
        XCTAssertEqual(slug, slug.lowercased())
        // Only lowercase ascii alphanumerics and hyphens, no leading/trailing hyphen.
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-")
        XCTAssertTrue(slug.unicodeScalars.allSatisfy { allowed.contains($0) }, "unexpected chars in \(slug)")
        XCTAssertFalse(slug.hasPrefix("-"))
        XCTAssertFalse(slug.hasSuffix("-"))
    }
}
