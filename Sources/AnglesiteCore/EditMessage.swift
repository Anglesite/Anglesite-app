import Foundation

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

    /// App-side conveniences for `op` strings, so callers don't sprinkle free string literals
    /// across the codebase. The wire format stays a `String` (the plugin defines the
    /// authoritative `apply_edit` op set in its MCP schema) — these are just typed names that
    /// make the app↔plugin pairing grep-able and rename-safe on our side.
    ///
    /// New ops on the plugin side need a paired entry here so call sites get a compile-time
    /// reference rather than a runtime mismatch via typo.
    public enum Op {
        /// `"replace-text"` — overlay click-to-edit, structured text replacement.
        public static let replaceText = "replace-text"
        /// `"replace-image-src"` — overlay image-drop replacement.
        public static let replaceImageSrc = "replace-image-src"
        /// `"replace-attr"` — generic attribute set (e.g. `href`, `alt`).
        public static let replaceAttr = "replace-attr"
        /// `"apply-instruction"` — natural-language edit forwarded to the plugin for
        /// interpretation. Used by Siri AI's `EditContentIntent` (B.5 / #149). Paired plugin
        /// support is forward-looking; until it lands, `apply_edit` returns `.failed` for
        /// this op and the intent's dialog explains the situation.
        public static let applyInstruction = "apply-instruction"
    }

    /// Overlay-generated correlation ID so the JS side can match replies to the original message.
    public let id: String
    public let type: MessageType
    /// Page path (e.g. `/about/`).
    public let path: String
    /// Structured element metadata (`ElementInfo`) — the plugin's `server/selector.mjs` resolves
    /// this to a CSS selector server-side. The bridge is a relay; #18 records the decision.
    public let selector: JSONValue
    /// Edit operation — `"replace-text"`, `"replace-attr"`, etc. Phase 5 finalizes the taxonomy.
    public let op: String
    /// Operation payload — varies by `op`. Optional because some ops (e.g. `"delete"`) won't carry one.
    public let value: JSONValue?
    /// When `true`, the plugin performs a dry run and returns an `anglesite:edit-preview` body
    /// instead of applying the change. Used by `EditContentIntent` to show a before/after diff
    /// before committing. Defaults `false` so all existing call sites are unaffected.
    public let dryRun: Bool

    public init(id: String, type: MessageType, path: String, selector: JSONValue, op: String, value: JSONValue?, dryRun: Bool = false) {
        self.id = id
        self.type = type
        self.path = path
        self.selector = selector
        self.op = op
        self.value = value
        self.dryRun = dryRun
    }

    /// Round-trippable `JSONValue` representation — used as the `arguments` payload when the
    /// router forwards an edit to the plugin's `apply_edit` MCP tool (the `type` field stays as
    /// the WKWebView-side boundary tag `"anglesite:apply-edit"`; the plugin's schema accepts and
    /// ignores it since the tool name is authoritative server-side).
    public var jsonValue: JSONValue {
        var obj: [String: JSONValue] = [
            "id": .string(id),
            "type": .string(type.rawValue),
            "path": .string(path),
            "selector": selector,
            "op": .string(op),
        ]
        if let value { obj["value"] = value }
        if dryRun { obj["dry_run"] = .bool(true) }
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
