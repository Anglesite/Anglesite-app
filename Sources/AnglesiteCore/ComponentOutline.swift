import Foundation

/// Pure presentation logic for the Component Editor, kept in Core so it is
/// testable without the app target (hosted app tests don't run on CI).
public enum ComponentOutline {
    public struct Row: Sendable, Equatable, Identifiable {
        public let node: ComponentModel.Node
        public let depth: Int
        public var id: String { node.id }

        public init(node: ComponentModel.Node, depth: Int) {
            self.node = node
            self.depth = depth
        }
    }

    /// Depth-first rows for a flat SwiftUI List; the synthetic fragment root
    /// is skipped so depth 0 is the component's top-level markup.
    public static func rows(from root: ComponentModel.Node) -> [Row] {
        var rows: [Row] = []
        func visit(_ node: ComponentModel.Node, depth: Int) {
            rows.append(Row(node: node, depth: depth))
            for child in node.children { visit(child, depth: depth + 1) }
        }
        let topLevel = root.kind == .fragment ? root.children : [root]
        for node in topLevel { visit(node, depth: 0) }
        return rows
    }

    /// Exact source-loc match — the canvas reports the loc Astro stamped on
    /// the rendered element, which is the node's start position.
    public static func node(atLine line: Int, column: Int, in root: ComponentModel.Node) -> ComponentModel.Node? {
        if root.loc?.line == line, root.loc?.column == column { return root }
        for child in root.children {
            if let match = node(atLine: line, column: column, in: child) { return match }
        }
        return nil
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
