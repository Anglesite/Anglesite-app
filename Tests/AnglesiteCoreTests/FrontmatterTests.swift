// Tests/AnglesiteCoreTests/FrontmatterTests.swift
import Testing
import Foundation
@testable import AnglesiteCore

/// Native port of `server/content-frontmatter.mjs` — a deliberately minimal YAML-frontmatter
/// reader for the `list_content` scan. These tests pin it to the Node parser it replaces.
@Suite("Frontmatter")
struct FrontmatterTests {

    @Test("no frontmatter delimiter yields an empty map")
    func noFrontmatter() {
        #expect(Frontmatter.parse("# Just a heading\n\nbody").isEmpty)
        #expect(Frontmatter.parse("leading text\n---\ntitle: x\n---").isEmpty)
    }

    @Test("quoted and unquoted scalars")
    func scalars() {
        let fm = Frontmatter.parse("---\ntitle: Hello World\nslug: 'my-post'\nname: \"Quoted\"\n---\nbody")
        #expect(fm["title"] == .string("Hello World"))
        #expect(fm["slug"] == .string("my-post"))
        #expect(fm["name"] == .string("Quoted"))
    }

    @Test("booleans parse to bool, not string")
    func booleans() {
        let fm = Frontmatter.parse("---\ndraft: true\npublished: false\n---")
        #expect(fm["draft"] == .bool(true))
        #expect(fm["published"] == .bool(false))
    }

    @Test("inline arrays")
    func inlineArrays() {
        let fm = Frontmatter.parse("---\ntags: [swift, ios, \"web dev\"]\nempty: []\n---")
        #expect(fm["tags"] == .array(["swift", "ios", "web dev"]))
        #expect(fm["empty"] == .array([]))
    }

    @Test("block arrays on following indented dash lines")
    func blockArrays() {
        let fm = Frontmatter.parse("---\ntags:\n  - swift\n  - 'ios'\nother: x\n---")
        #expect(fm["tags"] == .array(["swift", "ios"]))
        #expect(fm["other"] == .string("x"))
    }

    @Test("comments and blank lines are skipped")
    func commentsSkipped() {
        let fm = Frontmatter.parse("---\n# a comment\ntitle: T\n\n# another\n---")
        #expect(fm["title"] == .string("T"))
        #expect(fm.count == 1)
    }

    @Test("indented (nested) keys are ignored as top-level fields")
    func nestedIgnored() {
        let fm = Frontmatter.parse("---\nauthor:\n  name: Dana\ntitle: T\n---")
        // `author:` has an empty value with no dash-lines → "" ; nested `name:` is indented, ignored.
        #expect(fm["name"] == nil)
        #expect(fm["author"] == .string(""))
        #expect(fm["title"] == .string("T"))
    }

    @Test("CRLF line endings are handled")
    func crlf() {
        let fm = Frontmatter.parse("---\r\ntitle: T\r\ndraft: true\r\n---\r\nbody")
        #expect(fm["title"] == .string("T"))
        #expect(fm["draft"] == .bool(true))
    }
}
