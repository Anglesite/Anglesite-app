import Testing
import Foundation
@testable import AnglesiteCore

@Suite struct CopyEditAuditorTests {
    @Test func factoryMatchesToolchain() {
        let auditor = CopyEditAuditorFactory.makeDefault()
        #if compiler(>=6.4) && canImport(FoundationModels)
        #expect(auditor != nil)
        #else
        #expect(auditor == nil)
        #endif
    }

    /// The protocol is the app-side seam — a fake must be able to stand in for the FM auditor.
    @Test func fakeAuditorSatisfiesProtocol() async {
        struct FakeAuditor: CopyEditAuditing {
            func audit(chunks: [ContentChunk], preamble: String?, siteID: String, siteDirectory: URL) async -> CopyEditReport {
                CopyEditReportBuilder.report(results: chunks.map { ($0, []) })
            }
        }
        let chunk = ContentChunk(route: "/a", title: nil, filePath: "src/pages/a.md", text: "x", truncated: false)
        let report = await FakeAuditor().audit(
            chunks: [chunk], preamble: nil, siteID: "s", siteDirectory: URL(fileURLWithPath: "/tmp"))
        #expect(report.auditedCount == 1)
    }
}
