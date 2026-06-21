// Tests/AnglesiteCoreTests/IntegrationScaffolderTests.swift
import Testing
import Foundation
@testable import AnglesiteCore

@Suite struct IntegrationScaffolderTests {
    func makeSource(withLayout: Bool = false) -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("apply-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: root.appendingPathComponent("src/layouts"), withIntermediateDirectories: true)
        if withLayout {
            try! "<body>\n<slot/>\n<!-- anglesite:body-end -->\n</body>\n"
                .write(to: root.appendingPathComponent("src/layouts/BaseLayout.astro"), atomically: true, encoding: .utf8)
        }
        return root
    }
    func collect(_ stream: AsyncStream<IntegrationScaffolder.SetupStep>) async -> [IntegrationScaffolder.SetupStep] {
        var out: [IntegrationScaffolder.SetupStep] = []
        for await s in stream { out.append(s) }
        return out
    }

    @Test func appliesCreateFileAndConfig() async {
        let src = makeSource()
        let plan = OperationPlan(integrationID: .donations, steps: [
            .createFile(relativePath: "src/components/DonationButton.astro", contents: "BTN"),
            .upsertConfig([ConfigKV(key: "DONATIONS_PROVIDER", value: "stripe")]),
            .addCSP(["js.stripe.com"]),
        ], warnings: [])
        let steps = await collect(IntegrationScaffolder().apply(plan, in: src))
        #expect(steps.contains(.done(integrationID: "donations")))
        #expect(try! String(contentsOf: src.appendingPathComponent("src/components/DonationButton.astro"), encoding: .utf8) == "BTN")
        let cfg = try! String(contentsOf: src.appendingPathComponent(".site-config"), encoding: .utf8)
        #expect(cfg.contains("DONATIONS_PROVIDER=stripe"))
        #expect(cfg.contains("SCRIPT_ALLOW=js.stripe.com"))
    }

    @Test func injectAnchorIsIdempotent() async {
        let src = makeSource(withLayout: true)
        let plan = OperationPlan(integrationID: .booking, steps: [
            .injectAnchor(relativeFile: "src/layouts/BaseLayout.astro", anchor: "<!-- anglesite:body-end -->",
                          id: "booking", snippet: "<BookingWidget/>"),
        ], warnings: [])
        _ = await collect(IntegrationScaffolder().apply(plan, in: src))
        _ = await collect(IntegrationScaffolder().apply(plan, in: src))  // twice
        let layout = try! String(contentsOf: src.appendingPathComponent("src/layouts/BaseLayout.astro"), encoding: .utf8)
        #expect(layout.components(separatedBy: "<!-- anglesite:booking:start -->").count == 2)  // exactly one block
    }

    @Test func injectAnchorFailsWhenAnchorMissing() async {
        let src = makeSource(withLayout: false)
        try! "<body></body>".write(to: src.appendingPathComponent("src/layouts/BaseLayout.astro"), atomically: true, encoding: .utf8)
        let plan = OperationPlan(integrationID: .booking, steps: [
            .injectAnchor(relativeFile: "src/layouts/BaseLayout.astro", anchor: "<!-- anglesite:body-end -->",
                          id: "booking", snippet: "<X/>"),
        ], warnings: [])
        let steps = await collect(IntegrationScaffolder().apply(plan, in: src))
        #expect(steps.contains { if case .failed = $0 { return true }; return false })
    }

    @Test func warnsRatherThanClobberingHandEditedFile() async {
        let src = makeSource()
        let path = src.appendingPathComponent("src/components/DonationButton.astro")
        try! FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        try! "HAND EDITED".write(to: path, atomically: true, encoding: .utf8)
        let plan = OperationPlan(integrationID: .donations, steps: [
            .createFile(relativePath: "src/components/DonationButton.astro", contents: "NEW"),
        ], warnings: [])
        let steps = await collect(IntegrationScaffolder().apply(plan, in: src))
        #expect(steps.contains { if case .warning = $0 { return true }; return false })
        #expect(try! String(contentsOf: path, encoding: .utf8) == "HAND EDITED")  // not clobbered
    }
}
