import Foundation

/// Builds the wire-format `EditMessage` payloads for the four Component Editor structure write
/// ops (`insert-node`, `move-node`, `remove-node`, `set-attr`). Pure and testable — no MCP/router
/// dependency, mirrors `ComponentStyleEditBuilder`'s shape exactly.
public enum ComponentStructureEditBuilder {
    /// New-node spec for `insertNode` — mirrors the plugin's `component.node` schema.
    public enum NodeSpec {
        case element(tag: String)
        case component(tag: String, componentPath: String)
        case slot(name: String? = nil)

        var jsonValue: JSONValue {
            switch self {
            case .element(let tag):
                return .object(["kind": .string("element"), "tag": .string(tag)])
            case .component(let tag, let componentPath):
                return .object(["kind": .string("component"), "tag": .string(tag), "componentPath": .string(componentPath)])
            case .slot(let name):
                var obj: [String: JSONValue] = ["kind": .string("slot")]
                if let name { obj["slotName"] = .string(name) }
                return .object(obj)
            }
        }
    }

    public static func insertNode(
        id: String,
        path: String,
        baseVersion: String,
        parentId: String,
        index: Int,
        node: NodeSpec
    ) -> EditMessage {
        EditMessage(
            id: id,
            path: path,
            selector: nil,
            op: EditMessage.Op.insertNode,
            component: .object([
                "path": .string(path),
                "baseVersion": .string(baseVersion),
                "parentId": .string(parentId),
                "index": .int(index),
                "node": node.jsonValue,
            ]),
            value: nil
        )
    }

    public static func moveNode(
        id: String,
        path: String,
        baseVersion: String,
        nodeId: String,
        newParentId: String,
        newIndex: Int
    ) -> EditMessage {
        EditMessage(
            id: id,
            path: path,
            selector: nil,
            op: EditMessage.Op.moveNode,
            component: .object([
                "path": .string(path),
                "baseVersion": .string(baseVersion),
                "nodeId": .string(nodeId),
                "newParentId": .string(newParentId),
                "newIndex": .int(newIndex),
            ]),
            value: nil
        )
    }

    public static func removeNode(
        id: String,
        path: String,
        baseVersion: String,
        nodeId: String
    ) -> EditMessage {
        EditMessage(
            id: id,
            path: path,
            selector: nil,
            op: EditMessage.Op.removeNode,
            component: .object([
                "path": .string(path),
                "baseVersion": .string(baseVersion),
                "nodeId": .string(nodeId),
            ]),
            value: nil
        )
    }

    /// `value: nil` removes the attribute (encodes as an explicit JSON `null`, distinct from
    /// omitting the field — the plugin schema treats `value === null` as "remove").
    public static func setAttr(
        id: String,
        path: String,
        baseVersion: String,
        nodeId: String,
        name: String,
        value: String?
    ) -> EditMessage {
        EditMessage(
            id: id,
            path: path,
            selector: nil,
            op: EditMessage.Op.setAttr,
            component: .object([
                "path": .string(path),
                "baseVersion": .string(baseVersion),
                "nodeId": .string(nodeId),
                "name": .string(name),
                "value": value.map(JSONValue.string) ?? .null,
            ]),
            value: nil
        )
    }
}
