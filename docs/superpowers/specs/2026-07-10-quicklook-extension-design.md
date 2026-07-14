# Quick Look preview + thumbnail extensions for `.anglesite` packages

Issue: [#621](https://github.com/Anglesite/Anglesite-app/issues/621) — the last unstarted item on the Phase 10 tracker (#34).

## Problem

`.anglesite` packages (#242) are Finder-opaque directories (`LSTypeIsPackage`, UTI `io.dwk.anglesite.site`). Without a Quick Look extension, ⌥Space on a site shows a generic folder preview and Finder's grid/icon views show a generic folder icon — neither is useful for identifying a site at a glance.

## Goals

- ⌥Space on a `.anglesite` package shows the site's display name, created date, content stats, and last-modified date — no dev server, no container boot, no Node.
- Finder icon/grid views show a distinctive thumbnail for `.anglesite` packages instead of a generic folder icon.
- Both extensions read only the package's own metadata and cheap file-layout facts; they never generate content, never boot a runtime.

## Non-goals

- Live preview of rendered site content (that's what the app's own WKWebView preview is for).
- Generating the cached home-page thumbnail image — this design only wires the *read* path for a cache that a future feature will populate.

## Architecture

Three new pieces:

1. **`AnglesiteQuickLookSupport`** — new SPM library target, peer of `AnglesiteSiteModel`. Pure stats-gathering, no UI, no Foundation Extensions API. Unit-testable under plain `swift test`.
2. **`AnglesiteQuickLookPreview`** — new `appex` target implementing `com.apple.quicklook.preview`.
3. **`AnglesiteQuickLookThumbnail`** — new `appex` target implementing `com.apple.quicklook.thumbnail`.

Both extensions depend on `AnglesiteQuickLookSupport` (and transitively `AnglesiteSiteModel`); neither links `AnglesiteCore`'s heavier graph (process supervision, MCP client, etc.) — deliberately out of reach for a fast, sandboxed preview surface.

## `AnglesiteQuickLookSupport`

One type: `PackagePreviewSummary`, built from an `AnglesitePackage`:

```swift
public struct PackagePreviewSummary: Sendable, Equatable {
    public let displayName: String
    public let createdDate: Date
    public let pageCount: Int
    public let collectionCounts: [(name: String, count: Int)]  // ordered by directory name
    public let sourceLastModified: Date?
    public let cachedThumbnailURL: URL?  // nil if the file doesn't exist

    public static func summarize(_ package: AnglesitePackage, fileManager: FileManager = .default) throws -> Self
}
```

`summarize`:
- Reads the `Info.plist` marker via `AnglesitePackage.readMarker` (throws `AnglesitePackage.PackageError` on a missing/corrupt marker — callers handle this as "not a readable site").
- Counts files directly under `Source/src/pages` (non-recursive at the page-file level is fine; Astro's `[collection]` catch-all route doesn't itself count as a page).
- For each subdirectory of `Source/src/content/`, counts files in it, producing one `(name, count)` entry per collection directory found on disk — generic across template changes, no hardcoded collection list.
- Resolves `Source/`'s most recent modification time via a shallow `FileManager.enumerator` scan (bounded: skips `node_modules`, `.git`, `dist` — matching `ProjectValidator`'s existing exclusions if any apply, otherwise a small explicit skip-list).
- Checks `package.quickLookThumbnailURL` (see below) for existence; sets `cachedThumbnailURL` only if the file is actually present.

### Cache path addition to `AnglesitePackage`

Add one computed property to `AnglesitePackage` (the layout's single source of truth, per its own doc comment) rather than to the QuickLook module:

```swift
/// Cached home-page thumbnail (nice-to-have, #621). Nothing writes this yet — a future feature
/// (e.g. captured on deploy) will populate it; the QuickLook thumbnail/preview extensions read it
/// if present and fall back to a generated placeholder otherwise.
public var quickLookThumbnailURL: URL { configURL.appendingPathComponent("quicklook-thumbnail.png", isDirectory: false) }
```

### Testing

`AnglesiteQuickLookSupportTests` (Swift Testing), using a temp-directory-built fake package per test:
- Correct page/collection counts against a fixture `Source/` tree.
- Missing marker → throws, caller-visible as a distinct case.
- `cachedThumbnailURL` nil when absent, populated when the file exists.
- Excluded directories (`node_modules`, `.git`) don't skew `sourceLastModified`.

## `AnglesiteQuickLookPreview`

- `Info.plist`: `NSExtension.NSExtensionPointIdentifier = com.apple.quicklook.preview`, `NSExtensionAttributes.QLSupportedContentTypes = [io.dwk.anglesite.site]`.
- `PreviewViewController: NSViewController, QLPreviewingController`:
  - `preparePreviewOfFile(at url: URL, completionHandler: @escaping (Error?) -> Void)`:
    - Builds `AnglesitePackage(url: url)`, calls `PackagePreviewSummary.summarize`.
    - On success: embeds a SwiftUI view (`NSHostingController` as a child view controller) rendering name, created date, page count, per-collection counts, last-modified, and the cached thumbnail image if present.
    - On failure (`PackageError`): embeds a plain fallback view — "Not a readable Anglesite site" — and still calls `completionHandler(nil)` (QuickLook has no good error-surfacing UI; a thrown error here just shows QuickLook's own generic failure chrome, so a friendly in-view message is preferable).
- Entitlements: `com.apple.security.app-sandbox` only. QuickLook grants transient sandbox read access to the previewed URL itself when it launches the extension — no security-scoped bookmark plumbing needed (matches the issue's stated constraint).

## `AnglesiteQuickLookThumbnail`

- `Info.plist`: `NSExtension.NSExtensionPointIdentifier = com.apple.quicklook.thumbnail`, same `QLSupportedContentTypes`.
- `ThumbnailProvider: QLThumbnailProvider`:
  - `provideThumbnail(for request: QLFileThumbnailRequest, handler: @escaping (QLThumbnailReply?, Error?) -> Void)`:
    - Reads the marker only (cheap — no full `summarize` needed just for a thumbnail); on failure, calls `handler(nil, error)` and lets Quick Look fall back to its default folder icon.
    - If `package.quickLookThumbnailURL` exists: `handler(QLThumbnailReply(imageFileURL: thatURL), nil)`.
    - Otherwise: `handler(QLThumbnailReply(contextSize: request.maximumSize) { context in ... }, nil)` — draws a rounded-rect badge with the site's monogram (first letter of display name) and the display name as a caption underneath, using Core Graphics + Core Text directly (no SwiftUI/ImageRenderer — unnecessary weight for a shape + two text draws).
- Entitlements: same as the preview extension.

## Build integration

`project.yml` additions:
- Two new `appex` targets (`AnglesiteQuickLookPreview`, `AnglesiteQuickLookThumbnail`), each with its own `Info.plist` under `Resources/QuickLookPreview/` / `Resources/QuickLookThumbnail/` and its own entitlements file, each depending on the `AnglesiteQuickLookSupport` SPM product.
- Both added to the `Anglesite` app target's `dependencies` with `embed: true`, so xcodegen wires the `Copy Files (PlugIns)` phase and appex code-signing automatically (same pattern Xcode uses for any embedded extension; no existing precedent in this repo to follow since this is the first appex target, so this is new but standard Xcode/xcodegen territory).
- `Package.swift`: new `AnglesiteQuickLookSupport` library product + target + test target, alongside the existing `AnglesiteSiteModel` entry.

## Testing plan

- `swift test` covers `AnglesiteQuickLookSupportTests` — the only unit-testable surface (matches CLAUDE.md's existing note that hosted extension/app-target logic isn't CI-testable; logic is kept in a testable library, UI stays thin).
- Manual GUI smoke before opening the PR: build, select a real `.anglesite` package in Finder, confirm ⌥Space shows the populated preview and grid view shows the generated monogram thumbnail. Noted as a checklist item in the PR description, not a separate tracked issue (small enough to do inline).

## Acceptance (from the issue)

Selecting a `.anglesite` package in Finder and pressing Space shows site name, dates, and basic content stats instead of a generic folder preview. Not an App Store submission blocker.
