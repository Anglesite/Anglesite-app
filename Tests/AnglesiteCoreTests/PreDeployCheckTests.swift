import Testing
import Foundation
@testable import AnglesiteCore

struct PreDeployCheckTests {
    private let siteDir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)

    // MARK: Happy path

    @Test func `Returns passed when script emits ok-true JSON`() async {
        let json = #"{"ok": true, "failures": [], "warnings": []}"#
        let check = PreDeployCheck(invoke: { _ in (stdout: json, exitCode: 0) })

        let outcome = await check.check(siteID: "mysite", siteDirectory: siteDir)

        guard case .passed(let warnings) = outcome else {
            Issue.record("expected .passed, got \(outcome)")
            return
        }
        #expect(warnings == [])
    }

    // MARK: Blocked

    @Test func `Returns blocked when script emits ok-false with failures`() async {
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
            Issue.record("expected .blocked, got \(outcome)")
            return
        }
        #expect(failures.count == 1)
        #expect(failures[0].category == .piiEmail)
        #expect(failures[0].file == "dist/index.html")
        #expect(failures[0].detail.contains("jane@yourbusiness.com"))
        #expect(failures[0].remediation.contains("PII_EMAIL_ALLOW"))
    }

    @Test func `Parses all five failure categories`() async {
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
            Issue.record("expected .blocked")
            return
        }
        #expect(
            Set(failures.map(\.category)) == Set([.piiEmail, .piiPhone, .exposedToken, .thirdPartyScript, .keystaticRoute])
        )
    }

    // MARK: Error paths

    @Test func `Returns error when invoker throws`() async {
        struct SpawnFailed: Error {}
        let check = PreDeployCheck(invoke: { _ in throw SpawnFailed() })

        let outcome = await check.check(siteID: "mysite", siteDirectory: siteDir)

        guard case .error(let reason) = outcome else {
            Issue.record("expected .error, got \(outcome)")
            return
        }
        #expect(reason.contains("couldn't run"), "\(reason)")
    }

    @Test func `Returns error when stdout is not parseable JSON`() async {
        // tsx not installed → "command not found" on stderr, no stdout, exit 127
        let check = PreDeployCheck(invoke: { _ in (stdout: "", exitCode: 127) })

        guard case .error(let reason) = await check.check(siteID: "mysite", siteDirectory: siteDir) else {
            Issue.record("expected .error")
            return
        }
        #expect(reason.contains("exit 127") || reason.contains("npm run build") || reason.contains("update"), "\(reason)")
    }

    @Test func `Returns error when JSON is malformed`() async {
        let check = PreDeployCheck(invoke: { _ in (stdout: "not json at all", exitCode: 0) })

        guard case .error = await check.check(siteID: "mysite", siteDirectory: siteDir) else {
            Issue.record("expected .error")
            return
        }
    }

    // MARK: Warnings pass-through

    @Test func `Warnings are returned alongside passed and blocked outcomes`() async {
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
            Issue.record("expected .passed")
            return
        }
        #expect(pw.count == 1)
        #expect(pw[0].category == .missingOgImage)

        let blockedCheck = PreDeployCheck(invoke: { _ in (stdout: blockedJSON, exitCode: 1) })
        guard case .blocked(_, let bw) = await blockedCheck.check(siteID: "mysite", siteDirectory: siteDir) else {
            Issue.record("expected .blocked")
            return
        }
        #expect(bw.count == 1)
        #expect(bw[0].category == .missingOgImage)
    }
}
