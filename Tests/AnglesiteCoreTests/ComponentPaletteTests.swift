import Foundation
import Testing
@testable import AnglesiteCore

@Suite struct ComponentPaletteTests {
    @Test("curated HTML elements are present")
    func curatedElements() {
        let items = ComponentPalette.items(projectComponents: [], excluding: nil)
        let tags = items.compactMap { item -> String? in
            if case .element(let tag) = item.kind { return tag }
            return nil
        }
        #expect(tags.contains("h1"))
        #expect(tags.contains("p"))
        #expect(tags.contains("img"))
        #expect(tags.contains("a"))
        #expect(tags.contains("div"))
        #expect(tags.contains("section"))
        #expect(tags.contains("ul"))
    }

    @Test("slot is present")
    func slotItem() {
        let items = ComponentPalette.items(projectComponents: [], excluding: nil)
        #expect(items.contains { if case .slot = $0.kind { return true }; return false })
    }

    @Test("project components become component items, name-sorted")
    func projectComponents() {
        let badge = FileRef(url: URL(fileURLWithPath: "/site/src/components/Badge.astro"), group: .components, name: "Badge.astro")
        let card = FileRef(url: URL(fileURLWithPath: "/site/src/components/Card.astro"), group: .components, name: "Card.astro")
        let items = ComponentPalette.items(projectComponents: [card, badge], excluding: nil)
        let componentItems = items.compactMap { item -> (String, String)? in
            if case .component(let tag, let path) = item.kind { return (tag, path) }
            return nil
        }
        #expect(componentItems.map { $0.0 } == ["Badge", "Card"])
        #expect(componentItems.first?.1.hasSuffix("Badge.astro") == true)
    }

    @Test("the component currently being edited is excluded from its own palette")
    func excludesSelf() {
        let badge = FileRef(url: URL(fileURLWithPath: "/site/src/components/Badge.astro"), group: .components, name: "Badge.astro")
        let card = FileRef(url: URL(fileURLWithPath: "/site/src/components/Card.astro"), group: .components, name: "Card.astro")
        let items = ComponentPalette.items(projectComponents: [card, badge], excluding: card)
        let names = items.compactMap { item -> String? in
            if case .component(let tag, _) = item.kind { return tag }
            return nil
        }
        #expect(names == ["Badge"])
    }
}
