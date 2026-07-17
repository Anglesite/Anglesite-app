import Testing
import Foundation
@testable import AnglesiteCore

struct ComponentOutlineTests {
    private func model() throws -> ComponentModel {
        try JSONDecoder().decode(ComponentModel.self, from: Data(ComponentModelTests.fixture.utf8))
    }

    @Test("Rows flatten the tree DFS with depths, skipping the fragment root") func rowsFlatten() throws {
        let rows = ComponentOutline.rows(from: try model().template)
        #expect(rows.map(\.node.id) == ["n1", "n2", "n3"])
        #expect(rows.map(\.depth) == [0, 1, 1])
    }

    @Test("a component-instance node's children are not expanded into rows")
    func sealedInstanceHidesChildren() {
        let slotFill = ComponentModel.Node(id: "n3", kind: .text, tag: nil, attrs: [], span: .init(start: nil, end: nil), loc: nil, text: "fill", children: [])
        let badge = ComponentModel.Node(id: "n2", kind: .component, tag: "Badge", attrs: [], span: .init(start: nil, end: nil), loc: nil, text: nil, children: [slotFill])
        let root = ComponentModel.Node(id: "n0", kind: .fragment, tag: nil, attrs: [], span: .init(start: nil, end: nil), loc: nil, text: nil, children: [badge])

        let rows = ComponentOutline.rows(from: root)
        #expect(rows.map(\.node.id) == ["n2"]) // n3 (the slot-fill text) never appears as a row
        #expect(rows.first?.isSealed == true)
    }

    @Test("a plain element's children still expand normally")
    func plainElementExpands() {
        let child = ComponentModel.Node(id: "n2", kind: .text, tag: nil, attrs: [], span: .init(start: nil, end: nil), loc: nil, text: "hi", children: [])
        let article = ComponentModel.Node(id: "n1", kind: .element, tag: "article", attrs: [], span: .init(start: nil, end: nil), loc: nil, text: nil, children: [child])
        let root = ComponentModel.Node(id: "n0", kind: .fragment, tag: nil, attrs: [], span: .init(start: nil, end: nil), loc: nil, text: nil, children: [article])

        let rows = ComponentOutline.rows(from: root)
        #expect(rows.map(\.node.id) == ["n1", "n2"])
        #expect(rows.first?.isSealed == false)
    }

    @Test(
        "isExtractable is true only for .element and .component node kinds",
        arguments: [
            (ComponentModel.Node.Kind.fragment, false),
            (ComponentModel.Node.Kind.element, true),
            (ComponentModel.Node.Kind.component, true),
            (ComponentModel.Node.Kind.expression, false),
            (ComponentModel.Node.Kind.slot, false),
            (ComponentModel.Node.Kind.text, false),
        ]
    )
    func isExtractable(kind: ComponentModel.Node.Kind, expected: Bool) {
        let node = ComponentModel.Node(id: "n0", kind: kind, tag: nil, attrs: [], span: .init(start: nil, end: nil), loc: nil, text: nil, children: [])
        #expect(ComponentOutline.isExtractable(node) == expected)
    }

    @Test("Loc lookup finds an exact line+column match") func locLookupExact() throws {
        let root = try model().template
        #expect(ComponentOutline.node(atLine: 7, column: 1, in: root)?.id == "n1")
        #expect(ComponentOutline.node(atLine: 99, column: 1, in: root) == nil)
    }

    @Test(
        "Loc lookup matches Astro's end-of-opening-tag annotation column, not the parse column",
        arguments: [
            // n1 parses at 7:1; the dev server annotates end-of-opening-tag,
            // e.g. `<article class="card">` closes around column 23. Any
            // reported column at or after the parse column, on the same
            // line, should resolve back to n1 (real-world case).
            23, 8, 2,
        ]
    )
    func locLookupOffsetColumn(reportedColumn: Int) throws {
        let root = try model().template
        #expect(ComponentOutline.node(atLine: 7, column: reportedColumn, in: root)?.id == "n1")
    }

    @Test("Loc lookup picks the closest preceding column among same-line candidates") func locLookupClosestPreceding() throws {
        // Two nodes on the same line (8:7 = n2, 8:20 synthetic sibling);
        // a reported column between them resolves to the nearer preceding one.
        let json = """
        {"id": "n0", "kind": "fragment", "tag": null, "attrs": [], "span": [0, 10], "loc": null, "children": [
          {"id": "a", "kind": "element", "tag": "span", "attrs": [], "span": [0, 1], "loc": {"line": 8, "column": 7}, "children": []},
          {"id": "b", "kind": "element", "tag": "em", "attrs": [], "span": [1, 2], "loc": {"line": 8, "column": 20}, "children": []}
        ]}
        """
        let root = try JSONDecoder().decode(ComponentModel.Node.self, from: Data(json.utf8))
        #expect(ComponentOutline.node(atLine: 8, column: 15, in: root)?.id == "a")
        #expect(ComponentOutline.node(atLine: 8, column: 20, in: root)?.id == "b")
        #expect(ComponentOutline.node(atLine: 8, column: 3, in: root) == nil)
    }

    @Test("Harness URL for nested components with props") func harnessURL() throws {
        let base = URL(string: "http://localhost:4321")!
        let url = HarnessURL.build(base: base, componentPath: "src/components/nav/Item.astro", props: ["title": "Hi"])
        #expect(url?.path == "/_anglesite/component/nav/Item")
        #expect(url?.query?.contains("props=") == true)

        let layout = HarnessURL.build(base: base, componentPath: "src/layouts/BaseLayout.astro", props: [:])
        #expect(layout?.path == "/_anglesite/component/BaseLayout")
        #expect(layout?.query == nil)

        #expect(HarnessURL.build(base: base, componentPath: "src/pages/index.astro", props: [:]) == nil)
    }

    @Test("Harness URL percent-encodes + in prop values instead of leaving it literal") func harnessURLPlusEncoding() throws {
        let base = URL(string: "http://localhost:4321")!
        let url = try #require(HarnessURL.build(base: base, componentPath: "src/components/Card.astro", props: ["title": "1 + 1"]))
        // A literal `+` in the query is decoded as a space by `URLSearchParams` on the harness
        // side, so the raw query string must carry it percent-encoded, not literal.
        #expect(url.query(percentEncoded: true)?.contains("+") == false)
        // And the round trip through URLComponents' own decoding recovers the original value.
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let propsJSON = try #require(components.queryItems?.first(where: { $0.name == "props" })?.value)
        let decoded = try JSONDecoder().decode([String: String].self, from: Data(propsJSON.utf8))
        #expect(decoded["title"] == "1 + 1")
    }

    @Test("Harness URL percent-encodes & and = in prop values instead of leaving them literal") func harnessURLAmpersandEqualsEncoding() throws {
        let base = URL(string: "http://localhost:4321")!
        let url = try #require(HarnessURL.build(base: base, componentPath: "src/components/Card.astro", props: ["title": "Save & Close = done"]))
        // `.urlQueryAllowed` treats RFC 3986 sub-delims like `&` and `=` as unreserved, but they're
        // parameter/key-value delimiters to `URLSearchParams` on the harness side — left literal,
        // they'd split the query into bogus extra parameters and corrupt the JSON payload.
        let rawQuery = try #require(url.query(percentEncoded: true))
        #expect(!rawQuery.dropFirst("props=".count).contains("&"))
        #expect(!rawQuery.dropFirst("props=".count).contains("="))
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let propsJSON = try #require(components.queryItems?.first(where: { $0.name == "props" })?.value)
        let decoded = try JSONDecoder().decode([String: String].self, from: Data(propsJSON.utf8))
        #expect(decoded["title"] == "Save & Close = done")
    }

    @Test("fileMatches compares the harness's vite-rooted file against the project-relative path") func fileMatchesTest() {
        #expect(ComponentOutline.fileMatches("/src/components/Card.astro", relativePath: "src/components/Card.astro"))
        #expect(ComponentOutline.fileMatches("src/components/Card.astro", relativePath: "src/components/Card.astro"))
        #expect(ComponentOutline.fileMatches("/Users/dev/site/src/components/Card.astro", relativePath: "src/components/Card.astro"))
        #expect(!ComponentOutline.fileMatches("/src/components/Other.astro", relativePath: "src/components/Card.astro"))
        #expect(!ComponentOutline.fileMatches(nil, relativePath: "src/components/Card.astro"))
        #expect(!ComponentOutline.fileMatches("", relativePath: "src/components/Card.astro"))
    }

    @Test("Knob defaults prefer declared defaults, else type samples") func knobDefaults() {
        #expect(KnobDefaults.value(for: .init(name: "n", type: "number", optional: true, defaultValue: "1")) == "1")
        #expect(KnobDefaults.value(for: .init(name: "t", type: "string", optional: false, defaultValue: "\"Hello\"")) == "Hello")
        #expect(KnobDefaults.value(for: .init(name: "t", type: "string", optional: false, defaultValue: nil)) == "Sample")
        #expect(KnobDefaults.value(for: .init(name: "b", type: "boolean", optional: false, defaultValue: nil)) == "false")
    }

    @Test("Astro component files resolve to the component editor") func editorKind() {
        let astro = FileRef(url: URL(fileURLWithPath: "/s/src/components/Card.astro"), group: .components, name: "Card.astro")
        #expect(EditorKind.resolve(for: astro) == .component)
        let css = FileRef(url: URL(fileURLWithPath: "/s/src/components/card.css"), group: .components, name: "card.css")
        #expect(EditorKind.resolve(for: css) == .text)
    }

    // MARK: - Outline drag-reorder/insert geometry and tree helpers (#493 review follow-up)

    @Test(
        "dropZone classifies row-local y into before/into/after thirds",
        arguments: [(1.0, ComponentOutline.DropZone.before), (11.0, .into), (21.0, .after)]
    )
    func dropZoneThirds(y: Double, expected: ComponentOutline.DropZone) {
        #expect(ComponentOutline.dropZone(y: y, rowHeight: 22) == expected)
    }

    /// A 3-level tree used by the tree-helper tests below:
    /// root(n0) > section(n1) > [p1(n2), p2(n3), p3(n4) > span(n5)]
    private func reorderFixtureRoot() -> ComponentModel.Node {
        let span = ComponentModel.Node(id: "n5", kind: .element, tag: "span", attrs: [], span: .init(start: nil, end: nil), loc: nil, text: nil, children: [])
        let p1 = ComponentModel.Node(id: "n2", kind: .element, tag: "p", attrs: [], span: .init(start: nil, end: nil), loc: nil, text: nil, children: [])
        let p2 = ComponentModel.Node(id: "n3", kind: .element, tag: "p", attrs: [], span: .init(start: nil, end: nil), loc: nil, text: nil, children: [])
        let p3 = ComponentModel.Node(id: "n4", kind: .element, tag: "p", attrs: [], span: .init(start: nil, end: nil), loc: nil, text: nil, children: [span])
        let section = ComponentModel.Node(id: "n1", kind: .element, tag: "section", attrs: [], span: .init(start: nil, end: nil), loc: nil, text: nil, children: [p1, p2, p3])
        return ComponentModel.Node(id: "n0", kind: .fragment, tag: nil, attrs: [], span: .init(start: nil, end: nil), loc: nil, text: nil, children: [section])
    }

    @Test("parentID finds the direct parent, and nil for the root or an unknown id") func parentIDLookup() {
        let root = reorderFixtureRoot()
        #expect(ComponentOutline.parentID(of: "n2", in: root) == "n1")
        #expect(ComponentOutline.parentID(of: "n5", in: root) == "n4")
        #expect(ComponentOutline.parentID(of: "n0", in: root) == nil)
        #expect(ComponentOutline.parentID(of: "missing", in: root) == nil)
    }

    @Test("childIndex finds a node's position among its parent's children") func childIndexLookup() {
        let root = reorderFixtureRoot()
        #expect(ComponentOutline.childIndex(of: "n2", underParent: "n1", in: root) == 0)
        #expect(ComponentOutline.childIndex(of: "n4", underParent: "n1", in: root) == 2)
        #expect(ComponentOutline.childIndex(of: "n2", underParent: "missing", in: root) == nil)
        #expect(ComponentOutline.childIndex(of: "missing", underParent: "n1", in: root) == nil)
    }

    @Test("isNodeOrDescendant is true for self and any depth of descendant, false for an ancestor or an unrelated sibling")
    func isNodeOrDescendantLookup() {
        let root = reorderFixtureRoot()
        #expect(ComponentOutline.isNodeOrDescendant("n1", of: "n1", in: root)) // self
        #expect(ComponentOutline.isNodeOrDescendant("n2", of: "n1", in: root)) // direct child
        #expect(ComponentOutline.isNodeOrDescendant("n5", of: "n1", in: root)) // grandchild
        #expect(!ComponentOutline.isNodeOrDescendant("n1", of: "n2", in: root)) // ancestor, not descendant
        #expect(!ComponentOutline.isNodeOrDescendant("n3", of: "n4", in: root)) // unrelated sibling
    }

    @Test("adjustedMoveIndex corrects the target index for the dragged node's own pre-removal position")
    func adjustedMoveIndexCorrection() {
        // Dragged node is BEFORE the target in the pre-removal list: removal shifts the target
        // (and every index computed from it) down by one.
        #expect(ComponentOutline.adjustedMoveIndex(targetIndex: 2, draggedIndex: 0) == 1)
        // Dragged node is AFTER the target: the target's position is unaffected by the removal.
        #expect(ComponentOutline.adjustedMoveIndex(targetIndex: 1, draggedIndex: 2) == 1)
        // No dragged-index context (e.g. a palette insert, not a reorder): pass through unchanged.
        #expect(ComponentOutline.adjustedMoveIndex(targetIndex: 1, draggedIndex: nil) == 1)
    }
}
