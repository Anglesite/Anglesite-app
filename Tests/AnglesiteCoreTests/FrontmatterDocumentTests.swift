// Tests/AnglesiteCoreTests/FrontmatterDocumentTests.swift
import Testing
import Foundation
@testable import AnglesiteCore

@Suite("FrontmatterDocument")
struct FrontmatterDocumentTests {

    @Test("unedited round-trip is the identity")
    func identity() {
        let src = """
        ---
        title: "Hello"
        draft: false
        tags:
          - a
          - b
        ---

        Body text here.
        """ + "\n"
        #expect(FrontmatterDocument.parse(src).serialized() == src)
    }

    @Test("reads scalar, bool, and array values")
    func reads() {
        let doc = FrontmatterDocument.parse("---\ntitle: \"Hi\"\ndraft: true\ntags: [x, y]\n---\nB\n")
        #expect(doc.value(for: "title") == .string("Hi"))
        #expect(doc.value(for: "draft") == .bool(true))
        #expect(doc.value(for: "tags") == .array(["x", "y"]))
        #expect(doc.value(for: "missing") == nil)
    }

    @Test("editing one field leaves untouched keys and body verbatim")
    func editPreserves() {
        let src = "---\ntitle: \"Old\"\nweirdKey: keep-me-exactly\ndraft: false\n---\n\nBody.\n"
        var doc = FrontmatterDocument.parse(src)
        doc.set(.string("New"), for: "title")
        let out = doc.serialized()
        #expect(out.contains("title: \"New\""))
        #expect(out.contains("weirdKey: keep-me-exactly"))   // unknown key preserved verbatim
        #expect(out.contains("draft: false"))
        #expect(out.hasSuffix("\n\nBody.\n"))                // body verbatim
    }

    @Test("setting a new key appends it")
    func appendsNewKey() {
        var doc = FrontmatterDocument.parse("---\ntitle: \"T\"\n---\nB\n")
        doc.set(.string("noreply@x.io"), for: "email")
        #expect(doc.serialized().contains("email: \"noreply@x.io\""))
        #expect(doc.value(for: "email") == .string("noreply@x.io"))
    }

    @Test("no-frontmatter source is all body")
    func noFrontmatter() {
        let doc = FrontmatterDocument.parse("# Heading\n\nbody\n")
        #expect(doc.keys.isEmpty)
        #expect(doc.body == "# Heading\n\nbody\n")
        #expect(doc.serialized() == "# Heading\n\nbody\n")
    }

    @Test("editing the body leaves frontmatter verbatim")
    func editBody() {
        var doc = FrontmatterDocument.parse("---\ntitle: \"T\"\n---\n\nold body\n")
        doc.body = "\nnew body\n"
        let out = doc.serialized()
        #expect(out.contains("title: \"T\""))
        #expect(out.hasSuffix("\nnew body\n"))
    }

    @Test("array set renders block form and round-trips")
    func arraySet() {
        var doc = FrontmatterDocument.parse("---\nhours: []\n---\n")
        doc.set(.array(["Mon 9-5", "Tue 9-5"]), for: "hours")
        let out = doc.serialized()
        let reparsed = FrontmatterDocument.parse(out)
        #expect(reparsed.value(for: "hours") == .array(["Mon 9-5", "Tue 9-5"]))
    }

    @Test("comments and blank lines inside frontmatter survive an unedited round-trip")
    func commentsSurvive() {
        let src = "---\ntitle: \"T\"\n# a comment\n\ndraft: false\n---\nB\n"
        #expect(FrontmatterDocument.parse(src).serialized() == src)
    }
}
