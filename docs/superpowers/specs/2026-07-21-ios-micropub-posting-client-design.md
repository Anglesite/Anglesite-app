# iOS Micropub posting client — design

**Date:** 2026-07-21
**Status:** Elaborates [#800](https://github.com/Anglesite/Anglesite-app/issues/800) (spec
2026-07-17, slice 4's app-side iOS scope) into an implementation-ready design. This document
**does not revise** any decision in
[`2026-07-17-blog-markdown-editor-publishing-design.md`](2026-07-17-blog-markdown-editor-publishing-design.md)
— it defers to that spec everywhere it already decided something (product shape, Micropub vs.
any alternative transport, canonicality model, conformance gating, error handling, core testing
plan) and fills the gaps that spec left open for the iOS surface specifically: standing up the
actual iOS app target (nothing runnable exists today), the navigation/scene model, App Store
packaging, a browse/list mechanism (Micropub's `q=source` reads one post, not a list), and
porting the two AppKit-only editor components to iOS idioms.
**Related:** #800 (this design's parent issue) · #71/#66 (deferred v2.0 remote-editing scope,
explicitly out of scope here) · #589 Phase 2 (iOS-against-LAN-runtime dev/test — orthogonal to
this design, not a dependency) · #355 (IndieAuth, closed) · the 2026-07-17 spec's §C.2, C.4–C.7.

## Goal

Ship the iOS/iPadOS Anglesite app as **the Micropub CMS posting client** the 2026-07-17 spec
already decided it should be: create, browse, edit, and delete content objects of any registered
type, offline-first, gated on a site's `@dwk/workers` V-3 conformance, with no local git, no
container, no MCP — only HTTPS calls to the site's own per-site Worker. Full mobile site editing
(code/theme/pages via a remote container) is explicitly deferred to v2.0 (#66/#71) and is not
part of this design.

## Current state this builds on

| Fact | Where |
|---|---|
| `Package.swift` declares only `.macOS("27.0")` — no iOS platform, no iOS app target in `project.yml` | `Package.swift:426` |
| `AnglesiteIOS` module exists but is two stub files behind `#if os(iOS)` — a `WKWebView` preview shell only, no editor, no app entry point | `Sources/AnglesiteIOS/RemotePreviewWebView.swift` |
| The content-type registry (10 field kinds, `draft` on every post-family type) is pure, platform-neutral Swift already in `AnglesiteCore` | `ContentTypeRegistry.swift:18-33`, `:212` |
| `TypedContentEditor` reads/writes field values against that registry — pure, no I/O | `TypedContentEditor.swift:19` |
| `WorkersConformanceStatus.gateStatus(for:)` already exists for exactly this gating purpose | `WorkersConformance.swift:67` |
| `MarkdownTextView` (the compose surface) is AppKit-only (`NSViewRepresentable` over `swift-markdown-engine`'s `NativeTextViewWrapper`) | `Sources/AnglesiteApp/MarkdownTextView.swift:1,25` |
| `TypedEntryEditorView` (typed-field form) is AppKit-only, uses `NSOpenPanel` directly for image fields | `Sources/AnglesiteApp/TypedEntryEditorView.swift:68,128` |
| `NativeContentOperations.createPost` derives post slugs — `MicropubClient`'s `mp-slug` must match | `NativeContentOperations.swift:94` |
| `KeychainStore` deliberately keeps the Cloudflare token `AfterFirstUnlockThisDeviceOnly`, off iCloud Keychain — irrelevant to this design since iOS auth is IndieAuth, a separate credential | `Platform/KeychainStore.swift:20` |
| Slices 1–3 of the parent spec (macOS Markdown editor, draft/publish model, `build:ci`/bake groundwork) are closed and merged | #797, #798, #799 (all closed) |
| Slice 4 (`MicropubClient`, IndieAuth onboarding, iOS posting client) is gated cross-repo on V-3 `@dwk/workers` conformance | #800 |

## 1. Product shape

One universal-purchase app (same bundle ID family as the Mac app — one App Store Connect
record covers macOS + iOS). The entire iOS product surface is the CMS-mode Micropub posting
client described below; there is no "advanced" or "configured" mode unlocking a live site
editor. The app is feature-gated end-to-end on `WorkersConformanceStatus.gateStatus(for: .v3)`:
for a site whose per-site Worker hasn't shipped V-3 (`@dwk/micropub`, `@dwk/webmention`,
`@dwk/websub`) yet, the app names the requirement rather than degrading silently or hiding the
app's purpose entirely.

## 2. iOS app target prerequisites

Nothing runnable exists today. Before any UI work:

- Add `.iOS(...)` to `Package.swift`'s `platforms` list (`Package.swift:426`).
- Audit target-by-target which existing modules build for iOS: `AnglesiteCore` and
  `AnglesiteBridge` are already platform-neutral; `AnglesiteIOS` is already `#if os(iOS)`-scoped;
  `AnglesiteContainer` stays macOS-only (the `includeContainer` flag at `Package.swift:57`
  already excludes it from non-Darwin builds, and it has no reason to exist on iOS either, since
  this design has no container path).
- New `project.yml` target: a SwiftUI iOS app with a minimal single-scene entry point (no scene
  restoration complexity beyond the site selection + in-progress draft state described in §4).
  Bundle ID reuses `io.dwk.anglesite` (the Mac target's own ID) rather than a distinct
  `io.dwk.anglesite.ios` — Apple's universal-purchase mechanism requires matching bundle IDs
  across platform binaries to associate them under one App Store Connect record.
- New CI build lane for the iOS target — none of the existing lanes (Linux portable, macOS
  `swift test`, `xcodebuild` for the Mac scheme) cover it.

## 3. Navigation & scene model

Single-scene app (no multi-window for v1 — matches the "leaner, capture-and-publish-oriented"
framing from #342, and the iOS/iPadOS platform spec treats multi-window as something to add only
when the product benefits, not a default). One `NavigationSplitView`-based shell, adaptive:

- **iPhone**: collapses to a `NavigationStack` — site picker → content-type list → post list →
  composer/detail, one screen at a time, standard back navigation.
- **iPad**: three-column split view — sites/content-types sidebar, post list, composer/detail —
  reflowing at Split View / Slide Over widths.

State to restore across backgrounding/interruption: current site selection and any in-progress
draft, as plain `Codable` state on disk. There is no local git clone or working-copy state to
reconcile (unlike the Mac app's `SiteWindowModel`) since this design has no on-device git.

## 4. Auth: IndieAuth, not the Mac's Cloudflare token

Per the parent spec's §C.5: a one-time onboarding flow — enter the site URL → discover the
`micropub` + IndieAuth endpoints from the site's own well-knowns (standard Micropub client
discovery) → `ASWebAuthenticationSession` sign-in (the user authenticates against *their own
site*) → resulting token stored in Keychain, scoped to this site's Micropub endpoint. This is
entirely separate from `KeychainStore`'s existing Cloudflare token entry (`Platform/KeychainStore.swift:20`)
— the phone never touches it, so that entry's `AfterFirstUnlockThisDeviceOnly` accessibility
needs no change and no iCloud sync.

## 5. Compose & data flow

- **Composer**: a new UIKit-hosted counterpart to `MarkdownTextView` (`UIViewRepresentable` over
  the same `swift-markdown-engine` substrate, which already supports both AppKit and UIKit) as
  the body surface, plus a registry-driven form for every non-body `ContentTypeField.Kind`
  (`ContentTypeRegistry.swift:21`) — `PhotosPicker`/`fileImporter` instead of
  `TypedEntryEditorView`'s `NSOpenPanel` calls.
- **Browse (gap-fill; not decided by the parent spec)**: Micropub's `q=source` reads exactly one
  post by URL — there's no "list all my posts" query in the protocol, and the parent spec never
  addresses browsing. This design reuses the site's own already-shipped public feed (`/feed.json`)
  for the list view: no auth, no new server endpoint, works even before IndieAuth onboarding
  completes. Selecting a post to edit then fetches its authoritative source via Micropub
  `q=source`.
- **Write**: `MicropubClient` in `AnglesiteCore` (shared with the Mac's CMS-mode save path per
  the parent spec's §C.6, so Mac and phone edits use one write path and can't diverge) —
  create/update/delete, `post-status: draft|published`, `mp-slug` derived to match
  `NativeContentOperations.createPost`'s slug logic (`NativeContentOperations.swift:94`), media
  through the Micropub media endpoint to R2.
- **Offline**: composing and local drafts work fully offline (plain local state, no network
  needed). Publishing enqueues a `URLSession` **background** upload task — not a manually-polled
  retry loop — so a queued post survives app suspension/termination and the system delivers it
  whenever connectivity returns.
- **Concurrent edits**: compare-and-swap via a `q=source` re-fetch on conflict, per the parent
  spec — Mac and phone share the same write path, so there's one conflict-resolution rule for
  both.
- **Publish**: flips `post-status` to `published`, which triggers the Worker-side bake; UI shows
  "published — site rebuilding" until the bake confirms a live URL. No local Markdown→HTML
  preview is rendered (would be a second Markdown implementation diverging from Astro's, per the
  parent spec) — the styled editor is the draft surface, the deployed site is the truth.

## 6. Error handling

Adopts the parent spec's error-handling model directly (it already covers the mobile path in
full): conformance gate not met → feature simply not offered, naming the requirement; Micropub
failures (unreachable/5xx → local queued draft with explicit retry; 401/403 → IndieAuth re-auth
flow); offline → composing/drafting fully works, sending visibly disabled with a "waiting for
network" state; bake lag → "published — site rebuilding," never a faked live URL; concurrent
edits → compare-and-swap via `q=source`.

Two additions specific to the iOS surface, not covered by the parent spec:

- `ASWebAuthenticationSession` cancellation or failure needs its own distinct state — it is not
  a network failure and should not be surfaced as one.
- Media picked via `PhotosPicker` needs a size/format check before the media-endpoint upload
  (capture/compression *UX* is explicitly out of scope per the parent spec, but a basic
  pre-upload size guard is error handling, not UX polish).

## 7. Testing

Extends the parent spec's `MicropubClient` unit-test plan (already scoped there: faked endpoint,
create/update/delete, `post-status`, `mp-slug`, media-endpoint flow, `q=source` round-trip,
401→re-auth, offline queue — same faked-seam style as `RemoteSandboxSiteRuntime`'s
`SandboxControlClient` tests) with:

- The UIKit `MarkdownTextView` counterpart: round-trip parity with the AppKit version (same
  byte-identity-after-edit-free-open/close guarantee).
- The registry-driven form renderer exercised against every `ContentTypeField.Kind` case.
- The new iOS target's build lane in CI (a real gap today — no lane builds it).
- One opt-in live e2e (gated like the parent spec's, real Cloudflare account, once V-3 packages
  exist): onboard via IndieAuth, browse the feed, edit a post via `q=source` + Micropub update,
  publish, confirm the bake produces a live URL.

## Out of scope

- Full mobile site editing — code/theme/pages via a remote container (#66/#71). A v2.0 feature
  per the parent spec's locked decision log; explicitly not revised by this design.
- Media capture/compression UX (transport is settled per the parent spec; UX is its own design).
- Android.
- Any git-based mobile transport — rejected in the parent spec's decision log (an earlier
  revision tried a phone-side SwiftGit2 clone; superseded by the Micropub decision).
- Multi-window / multiple scenes on iPad (§3) — not ruled out forever, just not v1.

## Open questions / risks

- **Browse-via-feed gap-fill** (§5) is this design's own addition, not something the parent spec
  or the workers repo has agreed to — it needs no new server endpoint, but should be confirmed
  compatible with whatever the workers repo ships for V-3 before implementation locks it in.
- **Background task delivery timing** is OS-scheduled, not immediate — the "queued, will send
  when possible" UI language must not imply a specific delivery time.
- **`swift-markdown-engine`'s UIKit support** is asserted by the parent spec's Part A survey but
  not yet exercised inside this codebase on iOS specifically — worth a small spike before
  committing to it as the composer substrate for this design's first slice.
