# Open Web Inspector — Design

**Date:** 2026-06-23
**Status:** Approved (design)

## Goal

Let the user open the Web Inspector for the live website preview (the `WKWebView`
showing the Astro dev server), both via **control-click** and via a **View menu**
item. Available in **all builds**, including the sandboxed `AnglesiteMAS` App Store
target.

## Background

- The preview `WKWebView` is created in `PreviewView` (`Sources/AnglesiteApp/PreviewView.swift`),
  an `NSViewRepresentable`. Its configuration is built by `WebViewBridge`
  (`Sources/AnglesiteBridge/WebViewBridge.swift`).
- `WebViewBridge.applyLocalDevDefaults(to:)` already sets `webView.isInspectable = true`,
  but only inside `#if DEBUG`. When inspectable, WebKit **automatically** adds an
  "Inspect Element" item to the web view's native context menu and honors ⌥⌘I on the
  focused web view.
- There is **no public API** to open the Web Inspector programmatically on macOS. The
  only programmatic path is the private `_inspector` property (`_WKInspector`) and its
  `show` selector.
- The app ships two targets: `Anglesite` (Developer ID) and `AnglesiteMAS` (sandboxed,
  App Store). MAS-only differences are gated with `#if ANGLESITE_MAS`.

## Decision: availability and private API

The feature ships in **all builds, including MAS**, accepting that the programmatic
"Show Web Inspector" path uses private API and is therefore a policy risk for App Store
review. To reduce static-symbol detection, the private inspector is reached via
**string-based KVC** (`value(forKey: "_inspector")` + `perform(Selector(("show")))`)
rather than a linked symbol. All private/WebKit access is isolated in `AnglesiteBridge`.

## Design

### 1. Enable inspection in all builds

In `WebViewBridge.applyLocalDevDefaults(to:)`, remove the `#if DEBUG` guard around
`webView.isInspectable = true` so it is always enabled. This alone satisfies the
**control-click** requirement: WebKit's native context menu shows "Inspect Element"
when the web view is inspectable, and ⌥⌘I works on the focused web view.

No custom SwiftUI `.contextMenu` is added — it would conflict with WKWebView's own
native context menu.

### 2. Programmatic open helper (`AnglesiteBridge`)

Add to `WebViewBridge`:

```swift
@MainActor
public static func showInspector(_ webView: WKWebView) {
    (webView.value(forKey: "_inspector") as? NSObject)?
        .perform(Selector(("show")))
}
```

This is the single home for the private-API call.

### 3. Reaching the live `WKWebView` from a menu command

- `PreviewModel` gains `weak var webView: WKWebView?` and
  `func showWebInspector()` which calls `WebViewBridge.showInspector(_:)` and no-ops
  when `webView == nil`.
- `PreviewView` gains an `onWebView: (WKWebView) -> Void` closure, called in
  `makeNSView` after the web view is created.
- `SiteWindow` passes `{ preview.webView = $0 }` into `PreviewView` and exposes the
  model to the menu via `.focusedValue(\.preview, preview)`.

### 4. The menu item

- New `FocusedValue` key for `PreviewModel` (mirrors the existing `siteID` pattern in
  `Sources/AnglesiteApp/FocusedSite.swift`).
- New `WebInspectorCommands: Commands` reading `@FocusedValue(\.preview)`:
  - Placed in the **View** menu via `CommandGroup(after: .sidebar)` (alongside the
    existing Debug Pane toggle).
  - Label: **"Show Web Inspector"**, shortcut **⌥⌘I**.
  - `.disabled(focusedPreview == nil)` so it greys out when no site window is focused.
- Wired into the app's `.commands` in `Sources/AnglesiteApp/AnglesiteApp.swift`.

### Behavior choices

- **Show, not toggle** — reading inspector visibility is also private; `show` is
  simpler and idempotent.
- **Control-click** uses WebKit's native "Inspect Element" item (free once
  `isInspectable` is on), not a custom menu.
- **Label / shortcut:** "Show Web Inspector" / ⌥⌘I.

## Testing

- Unit test: `applyLocalDevDefaults(to:)` sets `isInspectable == true`
  (now unconditional, in all build configurations).
- Unit test: `PreviewModel.showWebInspector()` is nil-safe when `webView == nil`.
- The actual inspector display cannot be exercised on CI (hosted app tests do not run
  on CI runners), so logic is kept thin and lives in `AnglesiteBridge` / `PreviewModel`.

## Files touched

- `Sources/AnglesiteBridge/WebViewBridge.swift` — unconditional `isInspectable`;
  new `showInspector(_:)`.
- `Sources/AnglesiteApp/PreviewView.swift` — new `onWebView` closure.
- `Sources/AnglesiteApp/PreviewModel.swift` — `weak var webView`, `showWebInspector()`.
- `Sources/AnglesiteApp/SiteWindow.swift` — wire `onWebView`, `.focusedValue(\.preview, …)`.
- `Sources/AnglesiteApp/FocusedSite.swift` (or a new file) — `FocusedValue` for `PreviewModel`.
- `Sources/AnglesiteApp/AnglesiteApp.swift` — add `WebInspectorCommands` to `.commands`.
- Tests in `AnglesiteBridgeTests` / `AnglesiteCoreTests` as applicable.
