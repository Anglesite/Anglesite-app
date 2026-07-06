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

    @Test("Loc lookup finds the matching node") func locLookup() throws {
        let root = try model().template
        #expect(ComponentOutline.node(atLine: 7, column: 1, in: root)?.id == "n1")
        #expect(ComponentOutline.node(atLine: 99, column: 1, in: root) == nil)
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
