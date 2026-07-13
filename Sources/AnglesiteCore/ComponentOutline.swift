import Foundation
// CoreTransferable is Darwin-only; ComponentOutline is in the Linux-portable target set
// (Package.swift's cross-platform-port purity sweep), so the drag-payload Transferable types
// below — pure data used by SwiftUI .draggable/.dropDestination in the app target (Task
// 16/17/18) — are gated off the off-Darwin build rather than pulled in unconditionally.
#if canImport(CoreTransferable)
import CoreTransferable
import UniformTypeIdentifiers
#endif

/// Pure presentation logic for the Component Editor, kept in Core so it is
/// testable without the app target (hosted app tests don't run on CI).
public enum ComponentOutline {
    public struct Row: Sendable, Equatable, Identifiable {
        public let node: ComponentModel.Node
        public let depth: Int
        /// True for a `kind == .component` node — its children are real markup (slot-fill
        /// content authored at the use site), but the outline treats the instance as opaque
        /// (spec §4.1): configure it via its attrs/props, or double-click to edit the
        /// component's own definition.
        public let isSealed: Bool
        public var id: String { node.id }

        public init(node: ComponentModel.Node, depth: Int, isSealed: Bool = false) {
            self.node = node
            self.depth = depth
            self.isSealed = isSealed
        }
    }

    /// Depth-first rows for a flat SwiftUI List; the synthetic fragment root
    /// is skipped so depth 0 is the component's top-level markup. A
    /// `kind == .component` node's children are never visited — the instance
    /// is sealed (spec §4.1), so its slot-fill markup never becomes rows.
    public static func rows(from root: ComponentModel.Node) -> [Row] {
        var rows: [Row] = []
        func visit(_ node: ComponentModel.Node, depth: Int) {
            let sealed = node.kind == .component
            rows.append(Row(node: node, depth: depth, isSealed: sealed))
            guard !sealed else { return }
            for child in node.children { visit(child, depth: depth + 1) }
        }
        let topLevel = root.kind == .fragment ? root.children : [root]
        for node in topLevel { visit(node, depth: 0) }
        return rows
    }

    /// Source-loc match — the canvas reports the loc Astro's dev server
    /// stamps on the rendered element via `data-astro-source-loc`, which is
    /// the END of the element's opening tag (verified against
    /// `@astrojs/compiler`'s `transform(..., { annotateSourceFile: true })`:
    /// an element parsed at line L column 1 is annotated `L:C` for some
    /// `C > 1`). The parser's own `loc` on `ComponentModel.Node` is the START
    /// of the tag, so lines always match but columns never do exactly.
    ///
    /// Match by line; among same-line candidates whose column is at or
    /// before the reported column (the annotation column is always ≥ the
    /// parse column of the same element), pick the greatest column — i.e.
    /// the closest preceding start position. An exact line+column match
    /// always wins first, in case some future emitter does annotate the
    /// start position.
    public static func node(atLine line: Int, column: Int, in root: ComponentModel.Node) -> ComponentModel.Node? {
        var exact: ComponentModel.Node?
        var bestOffset: ComponentModel.Node?
        var bestOffsetColumn = Int.min

        func visit(_ node: ComponentModel.Node) {
            if let loc = node.loc, loc.line == line {
                if loc.column == column, exact == nil {
                    exact = node
                } else if loc.column <= column, loc.column > bestOffsetColumn {
                    bestOffsetColumn = loc.column
                    bestOffset = node
                }
            }
            for child in node.children { visit(child) }
        }
        visit(root)

        return exact ?? bestOffset
    }
}

/// Builds harness-route URLs for the component canvas (route injected by the
/// template's anglesite-harness integration).
public enum HarnessURL {
    public static func build(base: URL, componentPath: String, props: [String: String]) -> URL? {
        let prefixes = ["src/components/", "src/layouts/"]
        guard let prefix = prefixes.first(where: { componentPath.hasPrefix($0) }),
              componentPath.hasSuffix(".astro")
        else { return nil }
        let name = String(componentPath.dropFirst(prefix.count).dropLast(".astro".count))
        guard var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else { return nil }
        components.path = "/_anglesite/component/" + name
        if !props.isEmpty,
           let data = try? JSONSerialization.data(withJSONObject: props, options: [.sortedKeys]),
           let json = String(data: data, encoding: .utf8) {
            components.queryItems = [URLQueryItem(name: "props", value: json)]
        }
        return components.url
    }
}

/// Sample prop values that make any component render standalone.
public enum KnobDefaults {
    public static func value(for prop: ComponentModel.Prop) -> String {
        if let declared = prop.defaultValue {
            return declared.trimmingCharacters(in: CharacterSet(charactersIn: "\"'`"))
        }
        switch prop.type {
        case "string": return "Sample"
        case "number": return "1"
        case "boolean": return "false"
        default: return ""
        }
    }
}

#if canImport(CoreTransferable)
/// Drag payload for an outline row being reordered/reparented (Task 16) — identifies the
/// component file being edited (guards against a cross-editor drop landing on the wrong
/// component's tree) and the node being moved.
public struct ComponentDragItem: Codable, Sendable, Transferable {
    public let fileID: String
    public let nodeID: String

    public init(fileID: String, nodeID: String) {
        self.fileID = fileID
        self.nodeID = nodeID
    }

    public static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .anglesiteComponentDragItem)
    }
}

/// Drag payload for a palette row being dropped into the outline or onto the canvas (Task 17/18).
public struct PaletteDragPayload: Codable, Sendable, Transferable {
    public let label: String
    public let kind: ComponentStructureEditBuilder.NodeSpec

    public init(label: String, kind: ComponentStructureEditBuilder.NodeSpec) {
        self.label = label
        self.kind = kind
    }

    public static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .anglesitePaletteDragPayload)
    }
}
#endif
