import AppIntents
import AnglesiteCore
import CoreGraphics
import Foundation

/// Per-WKWebView state holding the latest `VisibleElementReport` and mapping each element to
/// an `AppEntity`. AppKit's `appEntityUIElementProvider` (B.4 / #148) reads from this when
/// Siri hit-tests the preview pane; intents (B.5 / #149) reach in via `entity(for:)` to
/// resolve an `ElementEntity` id back to live state.
///
/// **One provider per site window** — siteID is captured at construction time. The
/// `SiteContentGraph` is shared (one actor across the app); the provider asks it on each
/// update so live indexing (new image lands, page renames) doesn't strand stale annotations.
///
/// **Mapping priority** (corrected vs the issue spec, see PR notes for #146):
///   1. `<img>` with a `src` matching an `ImageEntity` → `ImageEntity`
///   2. `data-anglesite-id` matches a `PostEntity.id` → `PostEntity`
///   3. `pagePath` matches a `PageEntity.route` → `PageEntity`
///   4. Otherwise → transient `ElementEntity`
///
/// As written in the issue, rules 2 and 3 are swapped; every visible element has a `pagePath`,
/// so rule 3 would make the PostEntity rule unreachable. The corrected order has data-id (an
/// explicit author annotation) outrank generic-page fallback.
@MainActor
public final class PreviewAnnotationProvider: ElementEntityProviding {
    public let siteID: String
    private let graph: SiteContentGraph
    private var annotated: [(rect: CGRect, entity: any AppEntity)] = []
    private var elementsByID: [String: ElementEntity] = [:]

    public init(siteID: String, graph: SiteContentGraph) {
        self.siteID = siteID
        self.graph = graph
    }

    /// Replace the current annotation set with one derived from `elements`. Each call is a
    /// full snapshot — the JS reporter sends complete batches, so partial updates would
    /// require tracking removals we don't otherwise need.
    public func update(_ elements: [VisibleElement]) async {
        let resolvedGraph = ContentGraphOverride.scoped ?? graph
        var nextAnnotated: [(rect: CGRect, entity: any AppEntity)] = []
        var nextElements: [String: ElementEntity] = [:]
        nextAnnotated.reserveCapacity(elements.count)

        for element in elements {
            let rect = CGRect(
                x: element.rect.x,
                y: element.rect.y,
                width: element.rect.width,
                height: element.rect.height
            )
            let entity = await resolve(element, graph: resolvedGraph)
            nextAnnotated.append((rect: rect, entity: entity))
            if let elementEntity = entity as? ElementEntity {
                nextElements[elementEntity.id] = elementEntity
            }
        }

        annotated = nextAnnotated
        elementsByID = nextElements
    }

    /// Returns the entity at this element id, or `nil` if the id isn't in the latest report.
    /// Currently supports `ElementEntity` ids only; the indexed entity types (Page/Post/Image)
    /// have their own queries via `SiteContentGraph`.
    public func entity(for elementID: String) -> ElementEntity? {
        elementsByID[elementID]
    }

    /// All annotated rects with their entities. Order matches the report's input order,
    /// which preserves the JS reporter's priority sort (heading > image > nav > interactive).
    public func annotations() -> [(rect: CGRect, entity: any AppEntity)] {
        annotated
    }

    // MARK: ElementEntityProviding

    public func elementEntity(forID id: String) -> ElementEntity? {
        elementsByID[id]
    }

    public func suggestedElementEntities() -> [ElementEntity] {
        Array(elementsByID.values)
    }

    // MARK: mapping

    private func resolve(_ element: VisibleElement, graph: SiteContentGraph) async -> any AppEntity {
        // Rule 1: image src matches an indexed asset for this site.
        if element.tag.uppercased() == "IMG", let src = element.src {
            for image in await graph.images(for: siteID) where imageMatches(image, src: src) {
                return ImageEntity(image)
            }
        }
        // Rule 2: data-anglesite-id (which the JS reporter surfaces as `element.id` when
        // present) looks like a known PostEntity id.
        if let post = await graph.post(id: element.id) {
            return PostEntity(post)
        }
        // Rule 3: pagePath matches a known page route.
        if let pagePath = element.pagePath {
            for page in await graph.pages(for: siteID) where page.route == pagePath {
                return PageEntity(page)
            }
        }
        // Rule 4: transient ElementEntity. Captures the structured selector for B.5 routing.
        return ElementEntity(
            id: ElementEntity.makeID(siteID: siteID, elementID: element.id),
            displayName: ElementEntity.makeDisplayName(tag: element.tag, hint: element.text),
            siteID: siteID,
            selector: ElementEntity.encodeSelector(element.selector),
            pagePath: element.pagePath ?? "/"
        )
    }
}

/// Match an image `src` against an indexed `SiteContentGraph.Image`. Sites reference images
/// in lots of shapes — absolute `/images/foo.png`, relative `images/foo.png`, and full URLs.
/// We compare on the trailing path segment first (cheap, catches the common case) and fall
/// back to a `hasSuffix` over the relative path (handles same-name files in different dirs).
private func imageMatches(_ image: SiteContentGraph.Image, src: String) -> Bool {
    if src.hasSuffix(image.relativePath) { return true }
    let srcFile = (src as NSString).lastPathComponent
    if !srcFile.isEmpty, srcFile == image.fileName { return true }
    return false
}
