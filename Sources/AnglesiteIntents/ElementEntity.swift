import AppIntents
import AnglesiteCore
import Foundation

/// Transient onscreen element entity — covers the fallback case in `PreviewAnnotationProvider`'s
/// mapping rules (B.2 / #146) where a visible DOM element doesn't correspond to any indexed
/// Page/Post/Image. Lets Siri say "edit this" against arbitrary headings, buttons, links, etc.
///
/// **Not `IndexedEntity`** — these are tied to the live overlay state and would churn Spotlight
/// constantly. Only `PreviewAnnotationProvider` can resolve them, and only while the WKWebView
/// is showing the page that produced them. Once that page navigates, the entity is gone.
///
/// **Selector field is a JSON string.** Stores the same structured `ElementInfo`-as-`JSONValue`
/// shape used by `EditMessage`, encoded so it survives `AppEntity` persistence as a plain
/// `String`. Call `selectorJSON()` to materialize the `JSONValue` for routing.
public struct ElementEntity: AppEntity, Identifiable, Sendable {
    public let id: String              // "{siteID}:element:{elementID}"
    public let displayName: String     // "h1 — Welcome to my site"
    public let siteID: String
    public let selector: String        // JSON-encoded `ElementInfo`
    public let pagePath: String

    public static var typeDisplayRepresentation: TypeDisplayRepresentation { "Element" }

    public var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(displayName)", subtitle: "\(pagePath)")
    }

    public static var defaultQuery = ElementEntityQuery()

    public init(id: String, displayName: String, siteID: String, selector: String, pagePath: String) {
        self.id = id
        self.displayName = displayName
        self.siteID = siteID
        self.selector = selector
        self.pagePath = pagePath
    }
}

extension ElementEntity {
    /// Compose the canonical entity id for an element. Same `"{siteID}:{kind}:{key}"` shape as
    /// `PageEntity` / `PostEntity` / `ImageEntity`, so a single string-based switch (e.g.
    /// `entityID.hasPrefix("\(siteID):element:")`) can route by kind.
    public static func makeID(siteID: String, elementID: String) -> String {
        "\(siteID):element:\(elementID)"
    }

    /// Compose "h1 — Welcome to my site" / "div — Go" / "img — banner.png".
    /// Tag is lowercased; the hint is truncated to 50 chars with an ellipsis when overlong.
    public static func makeDisplayName(tag: String, hint: String?) -> String {
        let tagPart = tag.lowercased()
        guard let raw = hint?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return tagPart
        }
        let collapsed = raw.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let truncated = collapsed.count > 50
            ? collapsed.prefix(49) + "\u{2026}"
            : Substring(collapsed)
        return "\(tagPart) \u{2014} \(truncated)"
    }

    /// Decode the JSON-string selector back into the structured `JSONValue` shape that
    /// `EditMessage.selector` requires. Returns `nil` when the string isn't a usable selector
    /// — callers treat that as "drop the edit", matching how `EditMessage.decode` rejects
    /// non-object selectors at the WKWebView boundary.
    ///
    /// "Usable" means: parses as JSON, is a JSON object, AND carries the `tag` field the
    /// plugin's `server/selector.mjs` needs to resolve. The `tag` guard is what catches the
    /// `encodeSelector("{}")` round-trip case — an empty object is technically valid JSON but
    /// would otherwise pass downstream and fail at the plugin with a less-actionable error.
    public func selectorJSON() -> JSONValue? {
        guard let data = selector.data(using: .utf8) else { return nil }
        guard let raw = try? JSONSerialization.jsonObject(with: data) else { return nil }
        guard let jv = JSONValue.from(raw), case .object(let dict) = jv else { return nil }
        guard dict["tag"] != nil else { return nil }
        return jv
    }

    /// Encode a structured selector to the string form stored on the entity. Round-trips with
    /// `selectorJSON()`. Non-object inputs return `"{}"` — `selectorJSON()`'s `tag` guard then
    /// rejects them on the way back, so the nil-on-bad-input contract holds end-to-end.
    public static func encodeSelector(_ selector: JSONValue) -> String {
        guard case .object = selector else { return "{}" }
        guard let data = try? JSONSerialization.data(withJSONObject: selector.rawValue) else { return "{}" }
        return String(data: data, encoding: .utf8) ?? "{}"
    }
}

/// Resolves `ElementEntity` references from `PreviewAnnotationProvider`'s live state — not
/// from `SiteContentGraph`. The provider is a `@MainActor` reference, so the query bounces
/// through the main actor for each lookup.
public struct ElementEntityQuery: EntityQuery {
    public init() {}

    public func entities(for identifiers: [String]) async throws -> [ElementEntity] {
        // No global registry of providers (each WKWebView owns one); resolution at this layer
        // is best-effort against the active scoped provider. Tests + the upcoming B.4 hookup
        // bind the override; production query paths run through the bound provider.
        guard let provider = await ElementEntityProviderOverride.scoped else { return [] }
        var out: [ElementEntity] = []
        for id in identifiers {
            if let entity = await provider.elementEntity(forID: id) {
                out.append(entity)
            }
        }
        return out
    }

    public func suggestedEntities() async throws -> [ElementEntity] {
        guard let provider = await ElementEntityProviderOverride.scoped else { return [] }
        return await provider.suggestedElementEntities()
    }
}

/// Indirection so `ElementEntityQuery` can find the live provider without coupling
/// `AnglesiteIntents` to a singleton. The app-level hookup (B.4) binds this at WKWebView
/// install time; tests bind a stub. `@MainActor` because `PreviewAnnotationProvider` is.
@MainActor
public enum ElementEntityProviderOverride {
    @TaskLocal public static var scoped: ElementEntityProviding?
}

/// What `ElementEntityQuery` needs from a provider. The concrete type
/// (`PreviewAnnotationProvider`) implements it; tests can stub it without touching the real
/// provider's state machine.
@MainActor
public protocol ElementEntityProviding: AnyObject, Sendable {
    func elementEntity(forID id: String) -> ElementEntity?
    func suggestedElementEntities() -> [ElementEntity]
}
