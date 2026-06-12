import AppIntents
import AnglesiteCore

/// Phase A content intents (A.5, #139). Thin adapters, like `SiteIntents`:
///
/// - **Reads** (`SearchContentIntent`, `SiteStatusIntent`) go straight to `SiteContentGraph` via
///   `@Dependency`, bypassed in tests by `ContentGraphOverride.scoped` (same seam the entity
///   queries use).
/// - **Preview** (`PreviewSiteIntent`) routes through `WindowRouter` like `OpenSiteIntent`.
/// - **Creates** (`AddPageIntent`, `AddPostIntent`) go through `ContentOperationsService`
///   (→ `HeadlessRuntimePool` → plugin `create_page`/`create_post`), bypassed by
///   `ContentOperationsOverride.scoped`.
///
/// `EditContentIntent` is intentionally absent in Phase A: turning a natural-language edit
/// description into a structured `apply_edit` needs the on-device model from Phase C (#155).
///
/// All dialog text is built by the pure `ContentDialogs` helpers so it's unit-testable without
/// the AppIntents runtime.

// MARK: - Search

public struct SearchContentIntent: AppIntent {
    public static var title: LocalizedStringResource = "Search Site Content"
    public static var description = IntentDescription("Search a site's pages, posts, and images.")

    @Parameter(title: "Site") public var site: SiteEntity
    @Parameter(title: "Search") public var query: String
    @Dependency private var graph: SiteContentGraph

    public init() {}

    public static var parameterSummary: some ParameterSummary {
        Summary("Search \(\.$site) for \(\.$query)")
    }

    public func perform() async throws -> some IntentResult & ProvidesDialog {
        let dialog = await Self.dialog(graph: ContentGraphOverride.scoped ?? graph, siteID: site.id, query: query)
        return .result(dialog: IntentDialog(stringLiteral: dialog))
    }

    /// Gather matches from the graph and format the spoken result. Static + graph-injected so the
    /// read+format wiring is unit-testable without the AppIntents runtime.
    static func dialog(graph: SiteContentGraph, siteID: String, query: String) async -> String {
        let pages = await graph.searchPages(siteID: siteID, matching: query)
        let posts = await graph.searchPosts(siteID: siteID, matching: query)
        let images = await graph.searchImages(siteID: siteID, matching: query)
        return ContentDialogs.search(query: query, pageCount: pages.count, postCount: posts.count, imageCount: images.count)
    }
}

// MARK: - Status

public struct SiteStatusIntent: AppIntent {
    public static var title: LocalizedStringResource = "Site Content Status"
    public static var description = IntentDescription("Report how much content a site has.")

    @Parameter(title: "Site") public var site: SiteEntity
    @Dependency private var graph: SiteContentGraph

    public init() {}

    public static var parameterSummary: some ParameterSummary { Summary("Status of \(\.$site)") }

    public func perform() async throws -> some IntentResult & ProvidesDialog {
        let dialog = await Self.dialog(graph: ContentGraphOverride.scoped ?? graph, siteID: site.id, siteName: site.displayName)
        return .result(dialog: IntentDialog(stringLiteral: dialog))
    }

    /// Gather counts from the graph and format the spoken result. Static + graph-injected so the
    /// read+format wiring is unit-testable without the AppIntents runtime.
    static func dialog(graph: SiteContentGraph, siteID: String, siteName: String) async -> String {
        let posts = await graph.posts(for: siteID)
        return ContentDialogs.status(
            siteName: siteName,
            pages: await graph.pages(for: siteID).count,
            posts: posts.count,
            drafts: posts.filter(\.draft).count,
            images: await graph.images(for: siteID).count
        )
    }
}

// MARK: - Preview

/// Opens the site window. `openAppWhenRun` brings Anglesite forward; the actual window open
/// happens via `WindowRouter`, which the "Sites" scene observes.
///
/// The `page` parameter is accepted (per the A.5 spec) but does not yet drive in-preview
/// navigation to that page — delivering the route to the right `SiteWindow`'s WKWebView is a
/// follow-up. Today the intent opens the site; the dialog deliberately doesn't claim more.
public struct PreviewSiteIntent: AppIntent {
    public static var title: LocalizedStringResource = "Preview Site"
    public static var description = IntentDescription("Open a site's live preview in Anglesite.")
    public static var openAppWhenRun = true

    @Parameter(title: "Site") public var site: SiteEntity
    @Parameter(title: "Page") public var page: PageEntity?

    public init() {}

    public static var parameterSummary: some ParameterSummary { Summary("Preview \(\.$site)") }

    @MainActor
    public func perform() async throws -> some IntentResult & ProvidesDialog {
        WindowRouter.shared.requestOpen(siteID: site.id)
        return .result(dialog: IntentDialog(stringLiteral: ContentDialogs.preview(siteName: site.displayName)))
    }
}

// MARK: - Add Page

public struct AddPageIntent: AppIntent {
    public static var title: LocalizedStringResource = "Add Page"
    public static var description = IntentDescription("Scaffold a new page on a site with Anglesite.")

    @Parameter(title: "Site") public var site: SiteEntity
    @Parameter(title: "Name") public var name: String
    @Parameter(title: "Route") public var route: String?
    @Dependency private var content: any ContentOperationsService

    public init() {}

    public static var parameterSummary: some ParameterSummary {
        Summary("Add page \(\.$name) to \(\.$site)")
    }

    public func perform() async throws -> some IntentResult & ProvidesDialog {
        let scoped = ContentOperationsOverride.scoped
        let svc = scoped ?? content
        // Spawning the plugin's Node MCP server on first use can exceed the default budget, so the
        // real call runs as a background task (extended time + Cancel) on Xcode 27; the scoped-test
        // path and the Xcode 26.3 fallback await inline. Mirrors SiteIntents (#128 cleanup pending).
        let result: ContentCreateResult
        if scoped != nil {
            result = await svc.createPage(siteID: site.id, name: name, route: route)
        } else {
            #if compiler(>=6.4)
            result = try await performBackgroundTask {
                await svc.createPage(siteID: site.id, name: name, route: route)
            } onCancel: { _ in }
            #else
            result = await svc.createPage(siteID: site.id, name: name, route: route)
            #endif
        }
        return .result(dialog: IntentDialog(stringLiteral: ContentDialogs.created(result, kind: .page, siteName: site.displayName)))
    }
}

// MARK: - Add Post

public struct AddPostIntent: AppIntent {
    public static var title: LocalizedStringResource = "Add Post"
    public static var description = IntentDescription("Scaffold a new draft post on a site with Anglesite.")

    @Parameter(title: "Site") public var site: SiteEntity
    @Parameter(title: "Title") public var title2: String
    @Parameter(title: "Collection") public var collection: String?
    @Parameter(title: "Slug") public var slug: String?
    @Dependency private var content: any ContentOperationsService

    public init() {}

    // `title` is taken by `AppIntent.title`; the parameter is `title2` but presents as "Title".
    public static var parameterSummary: some ParameterSummary {
        Summary("Add post \(\.$title2) to \(\.$site)")
    }

    public func perform() async throws -> some IntentResult & ProvidesDialog {
        let scoped = ContentOperationsOverride.scoped
        let svc = scoped ?? content
        let result: ContentCreateResult
        if scoped != nil {
            result = await svc.createPost(siteID: site.id, title: title2, collection: collection, slug: slug)
        } else {
            #if compiler(>=6.4)
            result = try await performBackgroundTask {
                await svc.createPost(siteID: site.id, title: title2, collection: collection, slug: slug)
            } onCancel: { _ in }
            #else
            result = await svc.createPost(siteID: site.id, title: title2, collection: collection, slug: slug)
            #endif
        }
        return .result(dialog: IntentDialog(stringLiteral: ContentDialogs.created(result, kind: .post, siteName: site.displayName)))
    }
}

// `LongRunningIntent` / `CancellableIntent`: the create intents may spawn the plugin's Node MCP
// server on first use, which can exceed the default budget. Gated until #128 (Xcode 27 on CI).
#if compiler(>=6.4)
extension AddPageIntent: LongRunningIntent, CancellableIntent {}
extension AddPostIntent: LongRunningIntent, CancellableIntent {}
#endif

// MARK: - Dialog formatting (pure, unit-testable)

public enum ContentDialogs {
    public enum CreateKind: String, Sendable { case page, post }

    public static func search(query: String, pageCount: Int, postCount: Int, imageCount: Int) -> String {
        let total = pageCount + postCount + imageCount
        guard total > 0 else { return "Nothing matched “\(query)”." }
        var parts: [String] = []
        if pageCount > 0 { parts.append(count(pageCount, "page")) }
        if postCount > 0 { parts.append(count(postCount, "post")) }
        if imageCount > 0 { parts.append(count(imageCount, "image")) }
        return "Found \(list(parts)) matching “\(query)”."
    }

    public static func status(siteName: String, pages: Int, posts: Int, drafts: Int, images: Int) -> String {
        let draftNote = drafts > 0 ? " (\(drafts) draft\(drafts == 1 ? "" : "s"))" : ""
        return "\(siteName) has \(count(pages, "page")), \(count(posts, "post"))\(draftNote), and \(count(images, "image"))."
    }

    public static func preview(siteName: String) -> String {
        "Opening \(siteName)."
    }

    public static func created(_ result: ContentCreateResult, kind: CreateKind, siteName: String) -> String {
        switch result {
        case .created(_, let identifier):
            return "Added a \(kind.rawValue) at \(identifier) on \(siteName)."
        case .siteNotFound:
            return "Couldn’t find \(siteName)."
        case .failed(let reason):
            return "Couldn’t add the \(kind.rawValue): \(reason)"
        }
    }

    private static func count(_ n: Int, _ noun: String) -> String { "\(n) \(noun)\(n == 1 ? "" : "s")" }

    /// "a", "a and b", "a, b, and c".
    private static func list(_ items: [String]) -> String {
        switch items.count {
        case 0: return ""
        case 1: return items[0]
        case 2: return "\(items[0]) and \(items[1])"
        default: return items.dropLast().joined(separator: ", ") + ", and " + items.last!
        }
    }
}
