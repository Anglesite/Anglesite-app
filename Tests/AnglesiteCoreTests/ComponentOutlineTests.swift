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
}
