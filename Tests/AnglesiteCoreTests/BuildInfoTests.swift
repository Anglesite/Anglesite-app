import XCTest
@testable import AnglesiteCore

final class BuildInfoTests: XCTestCase {
    func testSummaryContainsAppName() {
        XCTAssertTrue(BuildInfo.summary.contains("Anglesite"))
    }

    func testSummaryContainsPhase() {
        XCTAssertTrue(BuildInfo.summary.contains("phase 0"))
    }
}
