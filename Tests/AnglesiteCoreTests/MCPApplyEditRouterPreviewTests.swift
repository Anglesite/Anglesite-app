import Testing
import Foundation
@testable import AnglesiteCore

@Suite("MCPApplyEditRouter edit-preview parsing")
struct MCPApplyEditRouterPreviewTests {
    @Test("parseStructured recognizes an edit-preview body")
    func parsesPreview() throws {
        let body = #"{"type":"anglesite:edit-preview","id":"1","file":"src/pages/about.astro","range":{"start":0,"end":40},"op":"edit-style","before":"<h1>Hi</h1>","after":"<h1 class=\"ang-abc123\">Hi</h1>\n<style>\n  .ang-abc123 { color: teal; }\n</style>"}"#
        let parsed = MCPApplyEditRouter.parsePreview(body)
        #expect(parsed != nil)
        #expect(parsed?.file == "src/pages/about.astro")
        #expect(parsed?.op == "edit-style")
        #expect(parsed?.before == "<h1>Hi</h1>")
        #expect(parsed?.after.contains("color: teal") == true)
    }

    @Test("EditMessage.jsonValue includes dry_run only when set")
    func dryRunSerialization() {
        let off = EditMessage(id: "1", type: .applyEdit, path: "/a/", selector: .object([:]), op: "replace-text", value: .string("x"))
        let on = EditMessage(id: "1", type: .applyEdit, path: "/a/", selector: .object([:]), op: "replace-text", value: .string("x"), dryRun: true)
        guard case .object(let offObj) = off.jsonValue, case .object(let onObj) = on.jsonValue else { Issue.record("not objects"); return }
        #expect(offObj["dry_run"] == nil)
        #expect(onObj["dry_run"] == .bool(true))
    }
}
