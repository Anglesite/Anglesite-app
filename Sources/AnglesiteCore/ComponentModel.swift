import Foundation

/// Decoded result of the plugin's `get_component_model` MCP tool — a
/// read-only structured view of one `.astro` component (spec §2.2).
public struct ComponentModel: Sendable, Equatable, Codable {
    public let version: String
    public let path: String
    public let template: Node
    public let frontmatter: Frontmatter?
    public let styles: [StyleRule]
    public let clientScript: ScriptZone?

    public struct Node: Sendable, Equatable, Codable, Identifiable {
        public let id: String
        public let kind: Kind
        public let tag: String?
        public let attrs: [Attr]
        public let span: Span
        public let loc: Loc?
        public let text: String?
        public let children: [Node]

        public enum Kind: String, Sendable, Codable {
            case fragment, element, component, expression, slot, text
        }

        public init(id: String, kind: Kind, tag: String?, attrs: [Attr], span: Span, loc: Loc?, text: String?, children: [Node]) {
            self.id = id
            self.kind = kind
            self.tag = tag
            self.attrs = attrs
            self.span = span
            self.loc = loc
            self.text = text
            self.children = children
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(String.self, forKey: .id)
            kind = try c.decode(Kind.self, forKey: .kind)
            tag = try c.decodeIfPresent(String.self, forKey: .tag)
            attrs = try c.decodeIfPresent([Attr].self, forKey: .attrs) ?? []
            span = try c.decodeIfPresent(Span.self, forKey: .span) ?? Span(start: nil, end: nil)
            loc = try c.decodeIfPresent(Loc.self, forKey: .loc)
            text = try c.decodeIfPresent(String.self, forKey: .text)
            children = try c.decodeIfPresent([Node].self, forKey: .children) ?? []
        }
    }

    public struct Attr: Sendable, Equatable, Codable {
        public let name: String
        public let value: String?
        public init(name: String, value: String?) {
            self.name = name
            self.value = value
        }
    }

    /// Wire format is a two-element array `[start, end]`, either may be null.
    public struct Span: Sendable, Equatable, Codable {
        public let start: Int?
        public let end: Int?

        public init(start: Int?, end: Int?) {
            self.start = start
            self.end = end
        }

        public init(from decoder: Decoder) throws {
            var c = try decoder.unkeyedContainer()
            start = try c.decodeIfPresent(Int.self) ?? nil
            end = try c.decodeIfPresent(Int.self) ?? nil
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.unkeyedContainer()
            try c.encode(start)
            try c.encode(end)
        }
    }

    public struct Loc: Sendable, Equatable, Codable {
        public let line: Int
        public let column: Int
        public init(line: Int, column: Int) {
            self.line = line
            self.column = column
        }
    }

    public struct Frontmatter: Sendable, Equatable, Codable {
        public let source: String
        public let span: Span
        public let props: [Prop]
    }

    public struct Prop: Sendable, Equatable, Codable {
        public let name: String
        public let type: String
        public let optional: Bool
        public let defaultValue: String?

        enum CodingKeys: String, CodingKey {
            case name, type, optional
            case defaultValue = "default"
        }

        public init(name: String, type: String, optional: Bool, defaultValue: String?) {
            self.name = name
            self.type = type
            self.optional = optional
            self.defaultValue = defaultValue
        }
    }

    public struct StyleRule: Sendable, Equatable, Codable {
        public let selector: String
        public let media: String?
        public let span: Span
        public let declarations: [Declaration]
    }

    public struct Declaration: Sendable, Equatable, Codable {
        public let property: String
        public let value: String
        public let span: Span
    }

    public struct ScriptZone: Sendable, Equatable, Codable {
        public let source: String
        public let span: Span
    }
}
