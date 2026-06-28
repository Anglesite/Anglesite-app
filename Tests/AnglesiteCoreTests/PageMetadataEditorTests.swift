import Testing
@testable import AnglesiteCore

@Suite("PageMetadataEditor")
struct PageMetadataEditorTests {
    @Test("reads title and description from frontmatter")
    func reads() {
        let src = "---\ntitle: \"Hello\"\ndescription: \"A page\"\n---\n\nBody.\n"
        let m = PageMetadataEditor.read(src)
        #expect(m.title == "Hello")
        #expect(m.description == "A page")
    }

    @Test("missing fields default to empty")
    func defaults() {
        let m = PageMetadataEditor.read("---\ntitle: \"Only\"\n---\nB\n")
        #expect(m.title == "Only")
        #expect(m.description == "")
    }

    @Test("write changes only edited keys, preserving unknown keys and body")
    func writeChangedOnly() {
        let src = "---\ntitle: \"Old\"\ndescription: \"D\"\nweird: keep-me\n---\n\nBody.\n"
        let out = PageMetadataEditor.write(PageMetadata(title: "New", description: "D"), into: src)
        #expect(out.contains("title: \"New\""))
        #expect(out.contains("description: \"D\""))   // unchanged
        #expect(out.contains("weird: keep-me"))       // unknown key preserved
        #expect(out.hasSuffix("\n\nBody.\n"))         // body preserved
    }

    @Test("write adds missing keys")
    func writeAddsKeys() {
        let out = PageMetadataEditor.write(PageMetadata(title: "T", description: "New desc"),
                                           into: "---\ntitle: \"T\"\n---\nB\n")
        #expect(out.contains("description: \"New desc\""))
    }

    @Test("unedited round-trip is the identity")
    func identity() {
        let src = "---\ntitle: \"T\"\ndescription: \"D\"\n---\n\nBody.\n"
        let m = PageMetadataEditor.read(src)
        #expect(PageMetadataEditor.write(m, into: src) == src)
    }
}
