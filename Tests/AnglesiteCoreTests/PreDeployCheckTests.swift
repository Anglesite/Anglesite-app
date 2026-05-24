import XCTest
@testable import AnglesiteCore

final class PreDeployCheckTests: XCTestCase {
    private let siteDir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)

    // MARK: Happy path

    func testReturnsPassedWhenScriptEmitsOkTrueJSON() async {
        let json = #"{"ok": true, "failures": [], "warnings": []}"#
        let check = PreDeployCheck(invoke: { _ in (stdout: json, exitCode: 0) })

        let outcome = await check.check(siteID: "mysite", siteDirectory: siteDir)

        guard case .passed(let warnings) = outcome else {
            return XCTFail("expected .passed, got \(outcome)")
        }
        XCTAssertEqual(warnings, [])
    }

    // MARK: Blocked

    func testReturnsBlockedWhenScriptEmitsOkFalseWithFailures() async {
        let json = """
        {
          "ok": false,
          "failures": [
            {
              "category": "pii-email",
              "file": "dist/index.html",
              "detail": "Possible email address: jane@yourbusiness.com",
              "remediation": "Wrap the address in a `mailto:` link if it should be published, or add it to PII_EMAIL_ALLOW in .site-config."
            }
          ],
          "warnings": []
        }
        """
        let check = PreDeployCheck(invoke: { _ in (stdout: json, exitCode: 1) })

        let outcome = await check.check(siteID: "mysite", siteDirectory: siteDir)

        guard case .blocked(let failures, _) = outcome else {
            return XCTFail("expected .blocked, got \(outcome)")
        }
        XCTAssertEqual(failures.count, 1)
        XCTAssertEqual(failures[0].category, .piiEmail)
        XCTAssertEqual(failures[0].file, "dist/index.html")
        XCTAssertTrue(failures[0].detail.contains("jane@yourbusiness.com"))
        XCTAssertTrue(failures[0].remediation.contains("PII_EMAIL_ALLOW"))
    }

    func testParsesAllFiveFailureCategories() async {
        let json = """
        {
          "ok": false,
          "failures": [
            {"category": "pii-email", "file": "a", "detail": "d", "remediation": "r"},
            {"category": "pii-phone", "file": "a", "detail": "d", "remediation": "r"},
            {"category": "exposed-token", "file": "a", "detail": "d", "remediation": "r"},
            {"category": "third-party-script", "file": "a", "detail": "d", "remediation": "r"},
            {"category": "keystatic-route", "file": "a", "detail": "d", "remediation": "r"}
          ],
          "warnings": []
        }
        """
        let check = PreDeployCheck(invoke: { _ in (stdout: json, exitCode: 1) })

        guard case .blocked(let failures, _) = await check.check(siteID: "mysite", siteDirectory: siteDir) else {
            return XCTFail("expected .blocked")
        }
        XCTAssertEqual(
            Set(failures.map(\.category)),
            Set([.piiEmail, .piiPhone, .exposedToken, .thirdPartyScript, .keystaticRoute])
        )
    }

    // MARK: Error paths

    func testReturnsErrorWhenInvokerThrows() async {
        struct SpawnFailed: Error {}
        let check = PreDeployCheck(invoke: { _ in throw SpawnFailed() })

        let outcome = await check.check(siteID: "mysite", siteDirectory: siteDir)

        guard case .error(let reason) = outcome else {
            return XCTFail("expected .error, got \(outcome)")
        }
        XCTAssertTrue(reason.contains("couldn't run"), reason)
    }

    func testReturnsErrorWhenStdoutIsNotParseableJSON() async {
        // tsx not installed → "command not found" on stderr, no stdout, exit 127
        let check = PreDeployCheck(invoke: { _ in (stdout: "", exitCode: 127) })

        guard case .error(let reason) = await check.check(siteID: "mysite", siteDirectory: siteDir) else {
            return XCTFail("expected .error")
        }
        XCTAssertTrue(reason.contains("exit 127") || reason.contains("npm run build") || reason.contains("update"), reason)
    }

    func testReturnsErrorWhenJSONIsMalformed() async {
        let check = PreDeployCheck(invoke: { _ in (stdout: "not json at all", exitCode: 0) })

        guard case .error = await check.check(siteID: "mysite", siteDirectory: siteDir) else {
            return XCTFail("expected .error")
        }
    }

    // MARK: Warnings pass-through

    func testWarningsAreReturnedAlongsidePassedAndBlockedOutcomes() async {
        let warningJSON = """
        "warnings": [
          {"category": "missing-og-image", "detail": "No og:image meta tag.", "remediation": "Run `npm run ai-images`."}
        ]
        """
        let passedJSON = "{ \"ok\": true, \"failures\": [], \(warningJSON) }"
        let blockedJSON = """
        { "ok": false,
          "failures": [{"category": "pii-email", "file": "a", "detail": "d", "remediation": "r"}],
          \(warningJSON) }
        """

        let passedCheck = PreDeployCheck(invoke: { _ in (stdout: passedJSON, exitCode: 0) })
        guard case .passed(let pw) = await passedCheck.check(siteID: "mysite", siteDirectory: siteDir) else {
            return XCTFail("expected .passed")
        }
        XCTAssertEqual(pw.count, 1)
        XCTAssertEqual(pw[0].category, .missingOgImage)

        let blockedCheck = PreDeployCheck(invoke: { _ in (stdout: blockedJSON, exitCode: 1) })
        guard case .blocked(_, let bw) = await blockedCheck.check(siteID: "mysite", siteDirectory: siteDir) else {
            return XCTFail("expected .blocked")
        }
        XCTAssertEqual(bw.count, 1)
        XCTAssertEqual(bw[0].category, .missingOgImage)
    }
}
