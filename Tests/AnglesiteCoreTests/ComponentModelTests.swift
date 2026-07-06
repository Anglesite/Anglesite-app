import Testing
import Foundation
@testable import AnglesiteCore

struct ComponentModelTests {
    static let fixture = """
    {
      "version": "sha256:abc123def456",
      "path": "src/components/Card.astro",
      "template": {
        "id": "n0", "kind": "fragment", "tag": null, "attrs": [],
        "span": [0, 120], "loc": null,
        "children": [
          {
            "id": "n1", "kind": "element", "tag": "article",
            "attrs": [{"name": "class", "value": "card"}],
            "span": [80, 118], "loc": {"line": 7, "column": 1},
            "children": [
              {"id": "n2", "kind": "expression", "tag": null, "attrs": [], "span": [95, 102], "loc": {"line": 8, "column": 7}, "children": []},
              {"id": "n3", "kind": "slot", "tag": "slot", "attrs": [], "span": [null, null], "loc": {"line": 9, "column": 3}, "children": []}
            ]
          }
        ]
      },
      "frontmatter": {
        "source": "interface Props { title: string; }",
        "span": [4, 40],
        "props": [{"name": "title", "type": "string", "optional": false, "default": null}]
      },
      "styles": [
        {"selector": ".card", "media": null, "span": [130, 155],
         "declarations": [{"property": "padding", "value": "1rem", "span": [138, 152]}]}
      ],
      "clientScript": {"source": "console.log(1)", "span": [160, 175]}
    }
    """

    @Test("Decodes the full tool JSON") func decodesFixture() throws {
        let model = try JSONDecoder().decode(ComponentModel.self, from: Data(Self.fixture.utf8))
        #expect(model.version == "sha256:abc123def456")
        #expect(model.template.kind == .fragment)
        let article = model.template.children[0]
        #expect(article.tag == "article")
        #expect(article.attrs == [ComponentModel.Attr(name: "class", value: "card")])
        #expect(article.span == ComponentModel.Span(start: 80, end: 118))
        #expect(article.children[1].kind == .slot)
        #expect(article.children[1].span == ComponentModel.Span(start: nil, end: nil))
        #expect(model.frontmatter?.props == [
            ComponentModel.Prop(name: "title", type: "string", optional: false, defaultValue: nil)
        ])
        #expect(model.styles[0].declarations[0].property == "padding")
        #expect(model.clientScript?.source == "console.log(1)")
    }

    @Test("Round-trips through encode/decode") func roundTrips() throws {
        let model = try JSONDecoder().decode(ComponentModel.self, from: Data(Self.fixture.utf8))
        let data = try JSONEncoder().encode(model)
        let again = try JSONDecoder().decode(ComponentModel.self, from: data)
        #expect(again == model)
    }
}
