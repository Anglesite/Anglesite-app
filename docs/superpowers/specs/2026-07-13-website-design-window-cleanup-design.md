# Website Design Window Cleanup (#714) — Design

**Date:** 2026-07-13
**Issue:** [#714](https://github.com/Anglesite/Anglesite-app/issues/714)
**Status:** Approved by DWK 2026-07-13

## Goal

Reshape the per-site window toward the Apple Pages model the issue references:

- **Left sidebar** — the site as a *visitor* understands it: a URL tree of the built
  site's human-visible pages, not a source-file browser. `index.html` pinned first,
  then other HTML pages, then subdirectories. Differentiated icons for directories
  with an RSS feed (collections) vs. without, and for HTML files. Images, CSS, and
  JS are hidden.
- **Right inspector** — tabbed **Metadata | Style** for the current selection.
- **Toolbar** — common editing tools by default; site operations recede to the
  customization palette and menus.
- **Icons** — SF Symbols wherever a fitting one exists; where none does, an art
  brief covers the custom symbol (see §3).

This coordinates with the menu-bar/toolbar epic (#518): every demoted toolbar item
keeps its menu equivalent, per that epic's conventions.

## Non-goals / deferred to the next design phase

Explicitly out of scope here, by decision on 2026-07-13:

- **Navigator access to components, styles, and site-wide config.** Removing the
  Components / Styles / Metadata sidebar sections leaves component and CSS editing
  and the `Info.plist` editor with **no navigator entry point** until the next
  phase designs their access path (candidates discussed: selection-driven entry,
  a "Show Development Files" toggle, a sidebar mode switch). This is an accepted,
  temporary regression for power users.
- **Editable directory settings.** §6's settings surface is read-mostly in v1;
  making template, feed, and sitemap configuration *writable* requires template
  code changes and lands with the deferred phase.
- **Sitemap generation.** The template generates no sitemap today; the settings
  surface reports "Not configured".
- **Style-tab write operations.** Gated on Component Editor slice 2 (#492), which
  is itself gated on plugin zone-filter fixtures (Anglesite/anglesite#411).

## 1. Sidebar: the site as a URL tree

### Model (AnglesiteCore)

A new pure builder replaces `buildNavigatorTree` (NavigatorTree.swift):

```swift
public struct URLTreeNode: Identifiable, Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case home                       // "/" — pinned first
        case page                       // any other HTML page or collection entry
        case directory(hasFeed: Bool)   // URL path segment with children
    }
    public let id: String               // the route, e.g. "/notes/", "/about"
    public let title: String
    public let route: String
    public let kind: Kind
    public let children: [URLTreeNode]? // nil for leaves (hides List disclosure)
}

public func buildSiteURLTree(
    pages: [SiteContentGraph.Page],
    posts: [SiteContentGraph.Post],
    feedCollections: Set<String>,
    contentTypes: ContentTypeRegistry = .default
) -> [URLTreeNode]
```

Rules:

- **Sources:** page routes from `SiteContentGraph.Page.route` (ContentScanner
  already handles nested `src/pages` folders) and collection-entry routes from
  `postRoute(for:)` (`/<collection>/<slug>/`). Nothing else enters the tree — so
  images, CSS, JS, feed routes (`rss.xml` etc.), and components are hidden by
  construction.
- **Top level:** home (`/`) pinned first, then other top-level pages sorted by
  title, then directories sorted by title.
- **Directories:** one node per URL path segment that has children — collection
  folders (`/notes/`) and nested page folders (`/blog/`). Title is the registered
  content type's `displayName` (e.g. "Notes") when
  `ContentTypeRegistry.descriptor(forCollection:)` matches, else the capitalized
  segment.
- **Inside a directory:** the directory's own index page pinned first, then
  entries sorted by `publishDate` descending (visitor-facing collections are
  reverse-chronological), falling back to title for undated items, then nested
  subdirectories.
- **Feed detection:** `feedCollections` is computed by probing
  `Source/src/pages/<collection>/rss.xml.ts` — the template materializes one per
  feed-bearing collection (`src/lib/feeds.ts` `FEED_COLLECTIONS`). No template or
  plugin change is needed. The probe lives beside `SiteFileTree.scan` and refreshes
  with it.
- Node titles use `Page.title ?? route` and `Post.title`, matching what a visitor
  sees in the browser.

### Selection semantics

`NavigatorTarget` gains a case:

- `.route(String)` — unchanged: pages and entries navigate the preview and
  populate the inspector.
- `.directory(collection: String?, route: String)` — new: opens the directory
  settings surface in the main pane (§6). `collection` is set for
  `src/content`-backed directories, nil for plain nested page folders.
- `.file(FileRef)` — retained in the enum for the editor pipeline, but no sidebar
  row produces it any more.

### What leaves the sidebar

- The Pages / Posts / Collections / Components / Styles / Metadata sections
  (`FileGroup`-keyed `NavigatorSection`s).
- The synthetic **Cleanup** section: it is not part of the visitor's site. It
  moves to a **Site ▸ Cleanup…** menu command that presents the existing
  `ProjectCleanupModel` results (same rows, same actions) in the main pane.

### What carries over

- Inline Finder-style rename, and the context-menu Rename / Duplicate /
  Repurpose Post… / Delete commands, on page and entry rows, with the existing
  `canRename`/`canDelete`/`canDuplicate`/`canRepurpose` gating.
- Live refresh via `SiteContentGraph.changeStream()`.
- `@SceneStorage` sidebar visibility, widths, and the empty-state
  `ContentUnavailableView`.

## 2. Icons

| Node | Symbol | Notes |
|---|---|---|
| Home (`/`) | `house` | new to the app |
| HTML page / entry | `doc.richtext` | already the app's canonical page icon |
| Directory, no feed | `folder` | |
| Directory with feed | `folder` + `dot.radiowaves.up.forward` badge | composed in SwiftUI (ZStack overlay, badge bottom-trailing) until a custom symbol ships |

No stock SF Symbol exists for a feed-bearing folder (`folder.badge.rss` does not
exist), so the composite is the v1 rendering and §3's art brief covers the real
symbol — the exact fallback the issue prescribes.

## 3. Art brief

`docs/art-briefs/2026-07-13-folder-rss-symbol.md` (committed with this spec)
briefs a custom SF Symbol: a `folder` silhouette carrying an RSS badge
(quarter-arcs + dot) at bottom-trailing, drawn on the SF Symbols app template so
it tracks weights and the three scales, in monochrome + hierarchical renditions.

## 4. Inspector: Metadata | Style tabs

- `PageInspectorView` gains a Pages-style segmented control (**Metadata | Style**)
  above the existing chrome. Selected tab persists per window via
  `@SceneStorage("siteInspector.tab")`.
- **Metadata tab** — exactly today's content: `InspectorChrome` wrapping
  `TypedEntryForm` or `PageMetadataForm`, including dirty/Save, off-main load, and
  the external-change conflict alert.
- **Style tab (v1)** — a "styles for the current selection" surface: hosts the
  Component Editor's styles panel when an element selection exists, otherwise a
  `ContentUnavailableView` ("Select something on the page"). Write operations
  deepen with #492; this slice ships the tab shell and selection plumbing only.

## 5. Toolbar: editing tools default, ops recede

All existing frozen `SiteToolbarItemID`s survive — only `.defaultCustomization`
changes — plus one new frozen ID:

- **New `insert`** — a `plus` menu button: New Page…, New Post…, New Collection
  Entry…, New Component…, reusing the navigator content-command actions
  (2026-07-09 navigator-content-commands design).
- **Defaults:** `panes` (principal) · `insert` · `openInBrowser` · `deploy` ·
  `chat` · `inspector`.
- **Demoted to hidden palette:** `graph`, `backup`, `audit` — each already has a
  menu equivalent, satisfying #518's "menu is the durable path" convention.
- Already-hidden palette items are unchanged.

`SiteToolbarItemIDTests` extends to cover the new ID and the new default set.

## 6. Directory settings (main pane)

Selecting a directory row opens a **Collection Settings** surface in the main
pane (a new `mainPaneMode`-adjacent editor view, like `PlistEditorView`):

- Content type (registry `displayName`) and entry count.
- Detected feeds — RSS / Atom / JSON, probed from
  `src/pages/<collection>/{rss.xml,atom.xml,feed.json}.ts`, each linked to its
  preview URL.
- Template/layout in use (static dispatch: Hentry / Hevent / Hreview per the
  template's `[collection]/[...slug].astro`).
- Sitemap status ("Not configured" until the template gains one).

v1 is read-mostly; editability is deferred (see Non-goals). Plain nested page
folders (no collection) show the page list and route only. A directory
selection clears the inspector context (as non-route selections do today) —
directory configuration lives in this main-pane surface, not the inspector.

## Slices

1. **URL-tree navigator** — `URLTreeNode` + `buildSiteURLTree` + feed probe in
   AnglesiteCore; `SiteNavigatorView`/`SiteNavigatorModel` swap to the tree;
   icons + composite feed badge; Cleanup moves to Site menu; art brief committed.
2. **Directory selection + settings v1** — `.directory` target, Collection
   Settings surface.
3. **Inspector tabs** — segmented Metadata | Style, Style-tab shell.
4. **Toolbar re-curation** — `insert` item, default set change, demotions.

Each slice is independently shippable. Slice 2 depends on slice 1 (the
`.directory` target exists only in the new tree); slices 3 and 4 are fully
independent of the others and of each other.

## Testing

- Unit tests for `buildSiteURLTree`: home pinning (root and per-directory),
  top-level vs. directory sorting, reverse-chron entry order with undated
  fallback, feed-badge propagation, nested `src/pages` folders, percent-encoded
  collection/slug routes, empty site.
- Feed-probe tests against fixture directory layouts.
- `SiteNavigatorModel` tests updated for tree output and `.directory` selection.
- `SiteToolbarItemIDTests` updated for `insert` + new defaults.
- Full `swift test` before push (several suites string-match template markup).

## Risks

- **Power-user regression (accepted):** no navigator path to components/styles/
  config until the next phase; the deferral is deliberate and recorded above.
- **Feed probe couples to template layout:** if the template moves its feed
  routes, badges silently vanish. The probe is one function with fixture tests,
  so the coupling is cheap to update; a registry-level feed flag is the likely
  next-phase home.
- **Slug-keyed Post IDs:** `SiteContentGraph.Post.id` is keyed by slug only;
  identical slugs across collections would collide in the tree exactly as they
  do in today's navigator — no new exposure, noted for the next-phase registry
  work.
