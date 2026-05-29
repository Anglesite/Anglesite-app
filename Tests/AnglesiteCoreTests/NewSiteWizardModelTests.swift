import XCTest
@testable import AnglesiteCore

@MainActor
final class NewSiteWizardModelTests: XCTestCase {
    private func catalog() -> ThemeCatalog {
        ThemeCatalog(themes: [
            Theme(id: "classic", name: "Classic", blurb: "", swatch: [], cssVars: [:]),
            Theme(id: "warm", name: "Warm", blurb: "", swatch: [], cssVars: [:]),
        ])
    }

    func testPickingTypeSetsDefaultTheme() {
        let m = NewSiteWizardModel(catalog: catalog(), slugTaken: { _ in false })
        m.choose(type: .blog)               // default for .blog is "warm"
        XCTAssertEqual(m.draft.themeID, "warm")
    }

    func testCannotContinuePastDetailsWithEmptyOrTakenName() {
        let m = NewSiteWizardModel(catalog: catalog(), slugTaken: { $0 == "taken" })
        m.step = .details
        m.draft.name = ""
        XCTAssertFalse(m.canContinue)
        m.draft.name = "Taken"              // slug "taken"
        XCTAssertFalse(m.canContinue)
        XCTAssertNotNil(m.detailsError)
        m.draft.name = "Fresh One"
        XCTAssertTrue(m.canContinue)
    }

    func testSlugPreviewTracksName() {
        let m = NewSiteWizardModel(catalog: catalog(), slugTaken: { _ in false })
        m.draft.name = "My Cool Site"
        XCTAssertEqual(m.slugPreview, "my-cool-site")
    }
}
