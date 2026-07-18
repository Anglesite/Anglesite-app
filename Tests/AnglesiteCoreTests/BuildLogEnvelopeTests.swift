import Testing
import Foundation
@testable import AnglesiteCore

struct BuildLogEnvelopeTests {
    private let passedJSON = #"{"version": 1, "ok": true, "failures": [], "warnings": []}"#
    private let blockedJSON = #"""
    {"version": 1, "ok": false, "failures": [{"severity":"error","category":"pii-email","message":"Possible email found","file":"index.html"}], "warnings": []}
    """#

    @Test("A log with build noise before the trailing envelope decodes to .outcome(.passed)")
    func passedEnvelopeAfterBuildNoise() {
        let log = """
        > astro build
        building client (vite)
        13 page(s) built in 842ms
        \(passedJSON)
        """
        let result = BuildLogEnvelope.extract(fromLog: log, exitCode: 0)
        guard case .outcome(.passed(let warnings)) = result else {
            Issue.record("expected .outcome(.passed), got \(result)")
            return
        }
        #expect(warnings.isEmpty)
    }

    @Test("A log with build noise before the trailing envelope decodes to .outcome(.blocked)")
    func blockedEnvelopeAfterBuildNoise() {
        let log = """
        > astro build
        building client (vite)
        13 page(s) built in 842ms
        \(blockedJSON)
        """
        let result = BuildLogEnvelope.extract(fromLog: log, exitCode: 1)
        guard case .outcome(.blocked(let failures, _)) = result else {
            Issue.record("expected .outcome(.blocked), got \(result)")
            return
        }
        #expect(failures.contains { $0.category == .piiEmail })
    }

    @Test("A log with no JSON envelope at all falls back to a raw excerpt")
    func noEnvelopeFallsBackToRawExcerpt() {
        let log = """
        > astro build
        Error: Cannot find module 'astro-embed'
        npm ERR! code MODULE_NOT_FOUND
        """
        let result = BuildLogEnvelope.extract(fromLog: log, exitCode: 1)
        guard case .rawExcerpt(let excerpt) = result else {
            Issue.record("expected .rawExcerpt, got \(result)")
            return
        }
        #expect(excerpt.contains("MODULE_NOT_FOUND"))
    }

    @Test("An empty log falls back to a raw excerpt, not a crash")
    func emptyLogFallsBackToRawExcerpt() {
        let result = BuildLogEnvelope.extract(fromLog: "", exitCode: 1)
        guard case .rawExcerpt(let excerpt) = result else {
            Issue.record("expected .rawExcerpt, got \(result)")
            return
        }
        #expect(excerpt.isEmpty)
    }

    @Test("The raw excerpt is capped to the last N lines for a very long non-JSON log")
    func rawExcerptIsCappedForLongLogs() {
        let lines = (1...500).map { "build noise line \($0)" }
        let log = lines.joined(separator: "\n")
        let result = BuildLogEnvelope.extract(fromLog: log, exitCode: 1)
        guard case .rawExcerpt(let excerpt) = result else {
            Issue.record("expected .rawExcerpt, got \(result)")
            return
        }
        let excerptLineCount = excerpt.split(separator: "\n", omittingEmptySubsequences: false).count
        #expect(excerptLineCount <= BuildLogEnvelope.rawExcerptLineLimit)
        #expect(excerpt.contains("build noise line 500"))
        #expect(!excerpt.contains("build noise line 1\n"))
    }
}
