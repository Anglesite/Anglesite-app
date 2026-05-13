import Foundation
import AnglesiteCore

/// One edit request flowing JS → native, decoded from the `WKScriptMessage.body` JSON dict.
///
/// The `type` field is strict — only message types we explicitly understand are accepted; everything
/// else is rejected at decode (rather than letting unknown types reach the router). New types need
/// an explicit `MessageType` case + decode update, which is the point: the WKWebView boundary is
/// untrusted input, so the contract is closed-set by design.
public struct EditMessage: Sendable, Equatable {
    public enum MessageType: String, Sendable, Equatable {
        /// Apply an edit to the underlying source — Phase 5 lands the server-side patcher and the
        /// exact `op` taxonomy. Until then this is the only accepted message type.
        case applyEdit = "anglesite:apply-edit"
    }

    /// Overlay-generated correlation ID so the JS side can match replies to the original message.
    public let id: String
    public let type: MessageType
    /// Page path (e.g. `/about/`).
    public let path: String
    /// Structured element metadata (`ElementInfo`) — the plugin's `server/selector.mjs` resolves
    /// this to a CSS selector server-side. The bridge is a relay; #18 records the decision.
    public let selector: JSONValue
    /// Edit operation — `"set-text"`, `"set-attribute"`, etc. Phase 5 finalizes the taxonomy.
    public let op: String
    /// Operation payload — varies by `op`. Optional because some ops (e.g. `"delete"`) won't carry one.
    public let value: JSONValue?

    public init(id: String, type: MessageType, path: String, selector: JSONValue, op: String, value: JSONValue?) {
        self.id = id
        self.type = type
        self.path = path
        self.selector = selector
        self.op = op
        self.value = value
    }

    /// Round-trippable `JSONValue` representation — used as the `arguments` payload when the
    /// router forwards an edit to the plugin's `anglesite:apply-edit` MCP tool.
    public var jsonValue: JSONValue {
        var obj: [String: JSONValue] = [
            "id": .string(id),
            "type": .string(type.rawValue),
            "path": .string(path),
            "selector": selector,
            "op": .string(op),
        ]
        if let value { obj["value"] = value }
        return .object(obj)
    }

    public enum DecodeError: Error, Sendable, Equatable {
        case notAnObject
        case missingField(String)
        case wrongType(field: String, expected: String)
        case unknownType(String)
    }

    /// Validate every field at the JS boundary; never throw. Returns a domain `Result` so callers
    /// can log the decode failure with the same machinery they use for everything else.
    public static func decode(from body: Any) -> Result<EditMessage, DecodeError> {
        guard let dict = body as? [String: Any] else { return .failure(.notAnObject) }
        // String-typed required fields, in the order callers see them in error messages.
        func requireString(_ field: String) -> Result<String, DecodeError> {
            guard let raw = dict[field] else { return .failure(.missingField(field)) }
            guard let s = raw as? String else { return .failure(.wrongType(field: field, expected: "string")) }
            return .success(s)
        }

        let id: String
        let typeRaw: String
        let path: String
        let op: String
        switch requireString("id") {
        case .success(let v): id = v
        case .failure(let e): return .failure(e)
        }
        switch requireString("type") {
        case .success(let v): typeRaw = v
        case .failure(let e): return .failure(e)
        }
        switch requireString("path") {
        case .success(let v): path = v
        case .failure(let e): return .failure(e)
        }
        switch requireString("op") {
        case .success(let v): op = v
        case .failure(let e): return .failure(e)
        }

        // `selector` is structured (`ElementInfo` shape) — require an object so it's
        // routable to the plugin's `selector.mjs.buildSelector(info)` unchanged. See #18.
        guard let rawSelector = dict["selector"] else { return .failure(.missingField("selector")) }
        guard let jv = JSONValue.from(rawSelector), case .object = jv else {
            return .failure(.wrongType(field: "selector", expected: "object"))
        }
        let selector = jv

        guard let type = MessageType(rawValue: typeRaw) else {
            return .failure(.unknownType(typeRaw))
        }

        // `value` is optional and polymorphic — accept anything `JSONValue.from` can model.
        let value: JSONValue?
        if let rawValue = dict["value"] {
            guard let jv = JSONValue.from(rawValue) else {
                return .failure(.wrongType(field: "value", expected: "JSON value"))
            }
            value = jv
        } else {
            value = nil
        }

        return .success(EditMessage(id: id, type: type, path: path, selector: selector, op: op, value: value))
    }
}
