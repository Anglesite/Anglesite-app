import XCTest
@testable import AnglesiteCore

final class HomepageWriterTests: XCTestCase {
    private let astro = """
    ---
    import BaseLayout from "../layouts/BaseLayout.astro";
    ---

    <BaseLayout
      title="Welcome — Your New Anglesite Business Website"
      description="Your business website is ready to set up. Run /start in Claude to begin the guided setup."
    >
      <h1>Welcome</h1>
      <p>This site is ready to set up. Type <code>/start</code> in Claude Desktop to get started.</p>
    </BaseLayout>
    """

    func testFillsHeadlineAndBlurb() {
        let out = HomepageWriter.fill(astro, headline: "Blue Bottle", blurb: "Neighborhood coffee in Oakland.", tagline: "Coffee, slow-roasted.")
        XCTAssertTrue(out.contains(#"title="Blue Bottle""#))
        XCTAssertTrue(out.contains(#"description="Neighborhood coffee in Oakland.""#))
        XCTAssertTrue(out.contains("<h1>Blue Bottle</h1>"))
        XCTAssertTrue(out.contains("<p>Neighborhood coffee in Oakland.</p>"))
        XCTAssertFalse(out.contains("/start"))
    }

    func testEmptyBlurbLeavesIntroDefaultAndUsesTaglineForDescription() {
        let out = HomepageWriter.fill(astro, headline: "Acme", blurb: "", tagline: "We do things.")
        XCTAssertTrue(out.contains(#"description="We do things.""#))
        XCTAssertTrue(out.contains("<h1>Acme</h1>"))
        // Intro paragraph untouched when no blurb:
        XCTAssertTrue(out.contains("Type <code>/start</code>"))
    }

    func testEscapesAttributeAndMarkup() {
        let out = HomepageWriter.fill(astro, headline: "Tom & \"Jerry\"", blurb: "1 < 2 & 3", tagline: "")
        XCTAssertTrue(out.contains(#"title="Tom &amp; &quot;Jerry&quot;""#))
        XCTAssertTrue(out.contains("<h1>Tom &amp; &quot;Jerry&quot;</h1>"))
        XCTAssertTrue(out.contains("<p>1 &lt; 2 &amp; 3</p>"))
    }
}
