import Foundation

/// Palette contents for the Component Editor's outline pane (spec §4.1): curated HTML
/// elements, `<slot>`, and the site's own project components. Pure/testable — no SwiftUI.
public enum ComponentPalette {
    public struct Item: Sendable, Equatable, Identifiable {
        public let id: String
        public let label: String
        public let kind: ComponentStructureEditBuilder.NodeSpec
        public let systemImage: String

        public init(id: String, label: String, kind: ComponentStructureEditBuilder.NodeSpec, systemImage: String) {
            self.id = id
            self.label = label
            self.kind = kind
            self.systemImage = systemImage
        }
    }

    /// Curated set, deliberately small: common structural/text/media elements, not the full
    /// HTML vocabulary. Order matches how they're grouped in the outline (headings, text,
    /// media, links/lists, layout).
    private static let curated: [(tag: String, label: String, systemImage: String)] = [
        ("h1", "Heading 1", "textformat.size.larger"),
        ("h2", "Heading 2", "textformat.size.larger"),
        ("h3", "Heading 3", "textformat.size"),
        ("p", "Paragraph", "text.alignleft"),
        ("img", "Image", "photo"),
        ("a", "Link", "link"),
        ("ul", "List", "list.bullet"),
        ("section", "Section", "square.split.bottomrightquarter"),
        ("div", "Div", "square.dashed"),
    ]

    public static func items(projectComponents: [FileRef], excluding current: FileRef?) -> [Item] {
        var result = curated.map { Item(id: "element:\($0.tag)", label: $0.label, kind: .element(tag: $0.tag), systemImage: $0.systemImage) }
        result.append(Item(id: "slot", label: "Slot", kind: .slot(), systemImage: "tray"))

        let components = projectComponents
            .filter { $0.id != current?.id }
            .sorted { $0.name < $1.name }
        for component in components {
            let tag = String(component.name.dropLast(".astro".count))
            result.append(Item(id: "component:\(component.id)", label: tag, kind: .component(tag: tag, componentPath: componentPath(for: component)), systemImage: "puzzlepiece.extension"))
        }
        return result
    }

    /// Best-effort project-relative path derivation for use as `NodeSpec.componentPath` — the
    /// palette only has the component's absolute `FileRef.url`; the plugin resolves the actual
    /// import specifier relative to the *edited* component's own path, so an approximate
    /// project-relative path (from the last `src/` segment onward) is sufficient here. Falls
    /// back to the full path if `src/` isn't found (defensive; every project component's URL
    /// contains `src/components/` or `src/layouts/` by construction — see `SiteFileTree`).
    private static func componentPath(for file: FileRef) -> String {
        let full = file.url.path(percentEncoded: false)
        if let range = full.range(of: "src/") {
            return String(full[range.lowerBound...])
        }
        return full
    }
}
