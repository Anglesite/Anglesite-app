import Foundation

/// One onscreen element reported by the WKWebView overlay's `installVisibleElementsReporter`
/// (JS, #145). The provider (`PreviewAnnotationProvider`, #146) maps each into an `AppEntity`
/// so Siri's `appEntityUIElementProvider` (#148) can resolve "this heading" / "this image"
/// hit-tests against whatever the user can currently see.
///
/// **Selector shape.** Same structured `ElementInfo`-as-`JSONValue` the `apply-edit` messages
/// carry — decided in #18 so the plugin's `server/selector.mjs` stays the only place that
/// turns metadata into a CSS selector. Decoder requires an object exactly like
/// `EditMessage.decode` does.
public struct VisibleElement: Sendable, Equatable {
    /// Per-tab stable id. Sourced from `data-anglesite-id` when present, otherwise a generated
    /// `v-…` string the JS layer keeps stable across reports via an internal WeakMap.
    public let id: String
    public let tag: String
    public let selector: JSONValue
    public let rect: Rect
    public let text: String?
    public let src: String?
    public let role: String?
    public let pagePath: String?

    public struct Rect: Sendable, Equatable {
        public let x: Double
        public let y: Double
        public let width: Double
        public let height: Double

        public init(x: Double, y: Double, width: Double, height: Double) {
            self.x = x
            self.y = y
            self.width = width
            self.height = height
        }
    }

    public init(
        id: String,
        tag: String,
        selector: JSONValue,
        rect: Rect,
        text: String? = nil,
        src: String? = nil,
        role: String? = nil,
        pagePath: String? = nil
    ) {
        self.id = id
        self.tag = tag
        self.selector = selector
        self.rect = rect
        self.text = text
        self.src = src
        self.role = role
        self.pagePath = pagePath
    }
}

/// The full `anglesite:visible-elements` payload — type tag plus the element list.
public struct VisibleElementReport: Sendable, Equatable {
    public static let messageType = "anglesite:visible-elements"

    public let elements: [VisibleElement]

    public init(elements: [VisibleElement]) {
        self.elements = elements
    }

    public enum DecodeError: Error, Sendable, Equatable {
        case notAnObject
        case missingField(String)
        case wrongType(field: String, expected: String)
        case unknownType(String)
        case malformedElement(index: Int, error: ElementDecodeError)
    }

    public enum ElementDecodeError: Error, Sendable, Equatable {
        case notAnObject
        case missingField(String)
        case wrongType(field: String, expected: String)
    }

    /// Validate every field at the JS boundary; never throw. Same flat `Result` shape as
    /// `EditMessage.decode` so the script handler can drop both through one error sink.
    public static func decode(from body: Any) -> Result<VisibleElementReport, DecodeError> {
        guard let dict = body as? [String: Any] else { return .failure(.notAnObject) }
        guard let rawType = dict["type"] else { return .failure(.missingField("type")) }
        guard let typeStr = rawType as? String else {
            return .failure(.wrongType(field: "type", expected: "string"))
        }
        guard typeStr == messageType else { return .failure(.unknownType(typeStr)) }

        guard let rawElements = dict["elements"] else { return .failure(.missingField("elements")) }
        guard let rawArray = rawElements as? [Any] else {
            return .failure(.wrongType(field: "elements", expected: "array"))
        }

        var elements: [VisibleElement] = []
        elements.reserveCapacity(rawArray.count)
        for (i, raw) in rawArray.enumerated() {
            switch VisibleElement.decode(from: raw) {
            case .success(let el): elements.append(el)
            case .failure(let err): return .failure(.malformedElement(index: i, error: err))
            }
        }
        return .success(VisibleElementReport(elements: elements))
    }
}

extension VisibleElement {
    /// Validate one element. Public so callers that already have a `[String: Any]` element
    /// (e.g. tests, alternate transports) can decode without going through the report wrapper.
    public static func decode(from body: Any) -> Result<VisibleElement, VisibleElementReport.ElementDecodeError> {
        guard let dict = body as? [String: Any] else { return .failure(.notAnObject) }
        func requireString(_ field: String) -> Result<String, VisibleElementReport.ElementDecodeError> {
            guard let raw = dict[field] else { return .failure(.missingField(field)) }
            guard let s = raw as? String else { return .failure(.wrongType(field: field, expected: "string")) }
            return .success(s)
        }
        let id: String
        let tag: String
        switch requireString("id") {
        case .success(let v): id = v
        case .failure(let e): return .failure(e)
        }
        switch requireString("tag") {
        case .success(let v): tag = v
        case .failure(let e): return .failure(e)
        }
        guard let rawSelector = dict["selector"] else { return .failure(.missingField("selector")) }
        guard let jv = JSONValue.from(rawSelector), case .object = jv else {
            return .failure(.wrongType(field: "selector", expected: "object"))
        }
        let selector = jv
        guard let rawRect = dict["rect"] else { return .failure(.missingField("rect")) }
        guard let rectDict = rawRect as? [String: Any] else {
            return .failure(.wrongType(field: "rect", expected: "object"))
        }
        guard
            let x = numberValue(rectDict["x"]),
            let y = numberValue(rectDict["y"]),
            let w = numberValue(rectDict["width"]),
            let h = numberValue(rectDict["height"])
        else {
            return .failure(.wrongType(field: "rect", expected: "{x,y,width,height} of numbers"))
        }
        let text = dict["text"] as? String
        let src = dict["src"] as? String
        let role = dict["role"] as? String
        let pagePath = dict["pagePath"] as? String
        return .success(
            VisibleElement(
                id: id,
                tag: tag,
                selector: selector,
                rect: Rect(x: x, y: y, width: w, height: h),
                text: text,
                src: src,
                role: role,
                pagePath: pagePath
            )
        )
    }
}

/// Accept either NSNumber (the `JSONSerialization` shape WKWebView delivers) or Swift numeric
/// literals (the shape tests construct). Mirrors `JSONValue.from`'s NSNumber-first ordering.
private func numberValue(_ raw: Any?) -> Double? {
    guard let raw else { return nil }
    if let n = raw as? NSNumber { return n.doubleValue }
    if let d = raw as? Double { return d }
    if let i = raw as? Int { return Double(i) }
    return nil
}
