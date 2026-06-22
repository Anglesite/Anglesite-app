// Tests/AnglesiteCoreTests/IntegrationOperationsTests.swift
import Testing
import Foundation
@testable import AnglesiteCore

@Suite struct IntegrationOperationsTests {
    func makeTemplate() -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("tmpl-\(UUID().uuidString)")
        // Task 3 moved integration components to the on-demand staging area integrations/components/.
        for p in ["integrations/components/Comments.astro"] {
            let url = root.appendingPathComponent(p)
            try! FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try! "C".write(to: url, atomically: true, encoding: .utf8)
        }
        return root
    }

    func makeSource(withBlogLayout: Bool) -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("src-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: root.appendingPathComponent("src/layouts"), withIntermediateDirectories: true)
        if withBlogLayout {
            // Layout carries both anchors: the frontmatter import anchor (line-style) and the
            // body render anchor (html-style). Giscus does a dual inject: imports first, then
            // the <Comments /> render tag.
            try! "---\n// anglesite:imports\n---\n<article><slot/><!-- anglesite:comments --></article>\n"
                .write(to: root.appendingPathComponent("src/layouts/BlogPost.astro"), atomically: true, encoding: .utf8)
        }
        return root
    }

    @Test func descriptorsExposesCatalog() {
        let ops = IntegrationOperations(sourceDirectory: { _ in nil }, templateDirectory: { nil })
        #expect(ops.descriptors().count == 3)
    }

    @Test func planThenApplySucceedsForGiscus() async {
        let src = makeSource(withBlogLayout: true)
        let tmpl = makeTemplate()
        let ops = IntegrationOperations(sourceDirectory: { _ in src }, templateDirectory: { tmpl })
        let answers: Answers = ["repo": "o/r", "repoId": "R", "category": "General", "categoryId": "C", "mapping": "pathname"]
        guard case .success(let plan) = await ops.plan(integrationID: .giscus, answers: answers, siteID: "s1") else {
            Issue.record("plan failed"); return
        }
        let terminal = await ops.apply(plan, siteID: "s1")
        #expect(terminal == .done(integrationID: "giscus"))
        let layout = try! String(contentsOf: src.appendingPathComponent("src/layouts/BlogPost.astro"), encoding: .utf8)
        #expect(layout.contains("<Comments"))
    }

    @Test func planFailsWhenSiteNotFound() async {
        let ops = IntegrationOperations(sourceDirectory: { _ in nil }, templateDirectory: { self.makeTemplate() })
        let r = await ops.plan(integrationID: .giscus, answers: [:], siteID: "missing")
        #expect(r == .failure(.siteNotFound))
    }

    func makeBookingTemplate() -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("tmpl-booking-\(UUID().uuidString)")
        for p in ["integrations/components/BookingWidget.astro", "integrations/pages/book.astro"] {
            let url = root.appendingPathComponent(p)
            try! FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try! "W".write(to: url, atomically: true, encoding: .utf8)
        }
        return root
    }

    func makeBookingSource() -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("src-booking-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: root.appendingPathComponent("src/layouts"), withIntermediateDirectories: true)
        try! "---\n// anglesite:imports\n---\n<body><slot/><!-- anglesite:body-end --></body>\n"
            .write(to: root.appendingPathComponent("src/layouts/BaseLayout.astro"), atomically: true, encoding: .utf8)
        return root
    }

    @Test func planThenApplySucceedsForBookingFloating() async {
        let src = makeBookingSource()
        let tmpl = makeBookingTemplate()
        let ops = IntegrationOperations(sourceDirectory: { _ in src }, templateDirectory: { tmpl })
        let answers: Answers = ["provider": "cal", "username": "jane", "style": "floating"]
        guard case .success(let plan) = await ops.plan(integrationID: .booking, answers: answers, siteID: "s1") else {
            Issue.record("plan failed"); return
        }
        let terminal = await ops.apply(plan, siteID: "s1")
        #expect(terminal == .done(integrationID: "booking"))
        let layout = try! String(contentsOf: src.appendingPathComponent("src/layouts/BaseLayout.astro"), encoding: .utf8)
        #expect(layout.contains("// anglesite:booking:start"))
        #expect(layout.contains("<!-- anglesite:booking:start -->"))
        #expect(FileManager.default.fileExists(atPath: src.appendingPathComponent("src/components/BookingWidget.astro").path))
        #expect(!FileManager.default.fileExists(atPath: src.appendingPathComponent("src/pages/book.astro").path))
    }

    @Test func planThenApplySucceedsForBookingInline() async {
        let src = makeBookingSource()
        let tmpl = makeBookingTemplate()
        let ops = IntegrationOperations(sourceDirectory: { _ in src }, templateDirectory: { tmpl })
        let answers: Answers = ["provider": "cal", "username": "jane", "style": "inline"]
        guard case .success(let plan) = await ops.plan(integrationID: .booking, answers: answers, siteID: "s1") else {
            Issue.record("plan failed"); return
        }
        let terminal = await ops.apply(plan, siteID: "s1")
        #expect(terminal == .done(integrationID: "booking"))
        #expect(FileManager.default.fileExists(atPath: src.appendingPathComponent("src/pages/book.astro").path))
        #expect(FileManager.default.fileExists(atPath: src.appendingPathComponent("src/components/BookingWidget.astro").path))
    }
}
