# Blog-post Markdown editor + container-less publishing — design

**Date:** 2026-07-17
**Status:** Proposed (brainstorm output; needs owner sign-off before implementation)
**Related:** #517 (Find + Format menu, blocked on editor work) · #288 (template blog system) · #346 (typed form editors) · #68 (repo bootstrap / Publish to GitHub) · #640/#654 (in-process git) · #742 (pre-deploy scan envelope) · #71/#66 (iOS thin client + remote sandbox) · #571 (cross-platform port) · epic #496 (Component Editor, STTextView precedent)

## Goal

Two coupled pieces:

1. **A native Markdown editor for blog posts** in the spirit of
   [nodes-app/swift-markdown-engine](https://github.com/nodes-app/swift-markdown-engine):
   a real text view with live in-place styling of Markdown source (headings sized, bold
   bold, task checkboxes toggleable) — not a raw monospaced buffer, and not a WYSIWYG
   that rewrites the file.
2. **A publish flow for posts that works on desktop and mobile**, where mobile is
   assumed to have **no container access at all** — no Apple Containerization, no Node,
   no subprocesses, and *not* the remote Cloudflare Sandbox either (that is a container
   too, just someone else's; it stays an orthogonal opt-in, per the
   2026-06-23 remote-sandbox design).

## Current state this builds on

| Fact | Where |
|---|---|
| Markdown bodies edit in a plain monospaced `TextEditor`; no styling, no Find, no Format menu | `MainPaneEditorView.swift:36`, `TypedEntryEditorView.swift:16` (#517 deferred both "pending editor work" — this is that work) |
| STTextView (TextKit 2, AppKit **and** UIKit) + Neon/tree-sitter are already approved, pinned dependencies, shipping in the Component Editor code panes | `Package.swift:307-333`, `ComponentEditorView.swift` |
| Git commits run **in-process** via SwiftGit2/libgit2 (App Sandbox can't exec `/usr/bin/git`); push over HTTPS exists (`HTTPRepoProvider`, #654) | `NativeContentOperations.swift:391`, `RepoBootstrap.swift`, `InProcessGit.swift` |
| Deploy **requires the container runtime**: build → pre-deploy scan → `wrangler deploy`, all in-container; host-Node paths are retired (#70) | `DeployCommand.swift:74-203`, `DeployModel.swift:328` |
| The pre-deploy gate is app-enforced today, with a versioned JSON envelope (#742) | `PreDeployCheck.swift`, `Resources/Template/scripts/pre-deploy-check.ts` |
| Template has a `blog` collection with a `draft` flag (#288); the typed post-family collections (`articles`, `notes`, …) have **no draft field**, and their zod schemas are `.strict()` | `Resources/Template/src/content.config.ts` |
| iOS today is a preview `WKWebView` shell only — no editor, no files, no app entry point | `Sources/AnglesiteIOS/` |
| Post-deploy Webmention/POSSE steps are pure Swift + HTTP | `DeployModel.swift:373-386`, `WebmentionSendCommand`, `POSSESyndicationCommand` |

The two facts that make the mobile story cheap: **git is already in-process** (libgit2
builds for iOS; the sandbox forced this on macOS, and iOS inherits it for free), and
**git is already the source of truth** (#72) — the app's working copy is explicitly
non-canonical, so a phone holding its own clone is architecturally normal, not a hack.

## Part A — the Markdown editor

### A.1 Substrate decision

**Chosen: STTextView + an in-house, UI-framework-free styling core.**

| Option | Verdict |
|---|---|
| **SwiftMarkdownEngine** (the referenced library) | Rejected as a dependency: AppKit-only, so it cannot cover iOS at all; it would be a *second* text-view substrate living beside the already-shipped STTextView; and it's a new third-party dep (policy: Apple frameworks only unless approved). It stays the **behavioral reference** — feature set and feel are what we're matching. |
| **STTextView** (already approved) | Chosen. TextKit 2, feature-complete AppKit *and* UIKit implementations (`STTextViewAppKit` / `STTextViewUIKit` over `STTextViewCommon`), plugin seam already proven in this app by the Component Editor code panes. One substrate for code panes and prose. |
| **SwiftUI `TextEditor` + `AttributedString`** (macOS 26+/iOS 26+) | Fallback, recorded. Zero-dep and cross-platform, but programmatic whole-document restyling on every keystroke fights the binding model (cursor/selection stability), and there is no plugin/interaction seam for checkbox taps or link handling. Revisit if STTextView's UIKit leg disappoints in practice. |
| **tree-sitter-markdown via the existing Neon plugin** | Insufficient alone: token *coloring* only — no per-block fonts/sizes (headings), paragraph styles (list indents, blockquotes), or interactive checkboxes. |

### A.2 Styling model (the swift-markdown-engine contract)

- **Attribute-only restyling of the raw source.** The editor never rewrites the text the
  user typed; Markdown remains byte-for-byte what lands on disk, so `git diff` stays
  human and external editors stay first-class (#72). Syntax markers (`#`, `**`, `` ` ``)
  remain visible, rendered dimmed.
- **v1 construct set:** ATX headings (sized fonts), bold/italic/strikethrough, inline
  code + fenced code blocks (monospaced, background; Neon-highlighted fences are a later
  nicety), links (styled + ⌘-click/tap to open), ordered/unordered lists with hanging
  indents, task-list checkboxes (tap/click toggles `[ ]`↔`[x]` — the one place the
  editor *does* write, a 1-character replacement through the normal undoable edit path),
  blockquotes.
- **Out of scope for v1:** LaTeX, wiki-links, table grid rendering, image thumbnail
  embedding (images render as styled links; inline thumbnails are a fast-follow).
- **Restyle strategy:** line-oriented incremental pass over the edited paragraph ±
  block-context (fences and lists need lookback), coalesced per edit. Blog posts are
  small; a full-document restyle is the correctness backstop and is acceptable up to
  tens of KB.

### A.3 Components

1. **`AnglesiteMarkdown`** *(new SwiftPM target, UI-framework-free)* — the tokenizer +
   styler: `MarkdownScanner` (source → block/inline nodes with source ranges) and
   `MarkdownTheme`/`MarkdownStyler` (nodes → attribute runs, platform fonts injected via
   a small `FontProviding` seam). No AppKit/UIKit imports, so it builds and tests on the
   Linux CI leg — consistent with the cross-platform port's purity rule (§10) and
   reusable later by the Linux/Windows shells (#571). Hand-rolled scanner for the styled
   subset; full CommonMark fidelity is *not* required because Astro remains the
   authoritative renderer.
2. **`MarkdownTextView`** *(AnglesiteApp / AnglesiteIOS)* — SwiftUI
   `NSViewRepresentable`/`UIViewRepresentable` hosting STTextView, applying
   `MarkdownStyler` output on text change; checkbox tap + link interaction handlers.
   Parallels the Component Editor's existing STTextView hosting.
3. **Editor wiring** — `EditorKind` gains `.markdown` (resolved for `.md`/`.mdx` in
   `.text`'s current fallthrough); `MainPaneEditorView` routes it to `MarkdownTextView`;
   `TypedEntryEditorView`'s body field swaps its `TextEditor` for `MarkdownTextView`.
   `FileEditorModel`/`TypedEntryEditorModel`, dirty tracking, conflict detection, and
   the per-edit-commit path are unchanged — this is a view-layer swap.
4. **#517 lands on top:** Format menu (⌘B/⌘I toggle delimiters, ⌘K wrap link, heading
   levels) as `MarkdownTextView` commands; Edit ▸ Find via the substrate's find support.
   Writing Tools come free with the native text view.

## Part B — the draft → publish content model

Publishing needs a state to flip. Today only the template `blog` collection has `draft`;
the typed post-family types have nothing.

1. **Template:** add `draft: z.boolean().default(false)` to the post-family collection
   schemas (`articles`, `notes`, `photos`, `albums`, `bookmarks`, `replies`, `likes`) —
   required because the schemas are `.strict()` and would otherwise *fail the build* on
   an unknown `draft` key. Every list route, detail-route `getStaticPaths`, and feed
   (RSS/Atom/JSON, mf2 rollups) filters `draft` entries, exactly as `/blog/` already
   does (#288). Business types (`announcements`, `events`, `reviews`, `members`) can
   follow later; posts are the target here.
2. **Registry:** the corresponding `ContentTypeRegistry` descriptors gain a
   `draft` field (`Kind.bool`) so the schema-driven form editor, intents, and scaffold
   see it. `ContentScaffold.renderEntry` writes new posts with `draft: true` — **new
   posts are drafts by default**; today's create-and-it's-live behavior becomes
   create-then-publish.
3. **Publish semantics:** "Publish" = set `draft: false`, re-stamp `publishDate` to now
   iff the entry has never been published (a draft's provisional date shouldn't become
   the public one; an explicitly user-edited date is respected), commit
   `anglesite: publish <type> <slug>` via the existing `processGitCommit` path.
   "Unpublish" is the inverse and is allowed — static rebuild makes it cheap.

Whether the legacy template `blog` collection and the typed `articles` collection should
merge is deliberately **not** decided here (open question); the editor and publish flow
work identically against both since both are Markdown + frontmatter collections.

## Part C — the publish pipelines

### C.1 Invariant

On every platform: **publish = commits on `Source/` + a deterministic pipeline that ends
in a deploy, with the pre-deploy security gate running somewhere the client cannot
skip, and build logs surfaced** (logs are sacred). No LLM in the loop anywhere.

### C.2 One seam, two strategies

A `PublishPipeline` protocol in AnglesiteCore with two implementations:

- **`ContainerPublishPipeline`** — the existing desktop path, unchanged:
  `DeployCommand` runs build → pre-deploy scan (#742 envelope, `.blocked` is final) →
  `wrangler deploy` inside the container runtime. Fast local iteration, no push
  required.
- **`GitPushPublishPipeline`** — the container-less path: commit → pull
  (fast-forward/rebase) → push to `origin` → **Cloudflare Workers Builds** (git-connected,
  user's account, user's billing — same BYO posture as everything else) builds and
  deploys → the app polls the Workers Builds deployment via the Cloudflare API and
  streams the build log into the debug pane.

Mobile only has the second. Desktop gets both — push-to-deploy is also the natural fit
for the Linux/Windows ports (#571) and for users who never provision the container
runtime. `DeployModel` picks the strategy the way it picks `ContainerDeployExecutor`
today.

### C.3 Moving the gate server-side (template change, app-only)

The template's CI story gets a `build:ci` script:

```jsonc
// Resources/Template/package.json
"build:ci": "npm run build && npx tsx scripts/pre-deploy-check.ts --json --strict"
```

Workers Builds is configured with build command `npm run build:ci` and deploy command
`npx wrangler deploy`. The scan runs **after** the build (it inspects `dist/`, matching
`DeployCommand`'s ordering) and a blocker exits non-zero, so **the deploy step never
runs**. This is strictly stronger than today's posture: the gate becomes unbypassable
from *any* client — the app, a laptop with `git push`, or a compromised device — rather
than being enforced by app code. The desktop container path keeps its local preflight
too (better UX: blocked before pushing anything). The scan's `--json` envelope (#742)
is emitted into the build log; on failure the app extracts it when present and renders
the existing `Phase.blocked` UI, falling back to a raw log excerpt for ordinary build
errors.

### C.4 Mobile flow end-to-end (no containers anywhere)

**Prerequisite:** the site has an `origin` remote — i.e. `RepoBootstrap` (#68,
"Publish to GitHub") has run. Mobile onboarding surfaces this as the entry requirement;
a site that exists only on one Mac's disk is not reachable from a phone *by design*
(git is the sync layer; there is no bespoke Anglesite sync protocol).

1. **Onboarding (once):** sign into the git host (GitHub OAuth device/web flow → token
   in Keychain, mirroring `HTTPGitHubClient`), pick the site repo, **shallow clone**
   `Source/` into the app's container directory via SwiftGit2 (libgit2 is already the
   Darwin git path; no subprocess involved). Connect Cloudflare with the existing
   verify-then-persist `TokenOnboarding` pattern; enable Workers Builds for the repo
   (§C.6).
2. **Edit:** the same navigator-lite → `TypedEntryEditorView` (ported off
   `NSOpenPanel`/`NSWorkspace` onto `fileImporter`/`PhotosPicker`) with
   `MarkdownTextView` bodies. `FrontmatterDocument` round-trip, per-edit commits —
   identical code, running against the local checkout. Offline editing works fully;
   commits accumulate locally.
3. **Draft reading:** the styled editor *is* the draft surface. There is **no fake
   local preview** — rendering Markdown to HTML app-side would be a second Markdown
   implementation that diverges from Astro's, shown in site-unlike CSS. Honest
   labeling over simulation. True preview = the deployed site post-publish (drafts
   never deploy), or the remote sandbox for users who separately opt into it.
4. **Publish:** flip draft (§B.3) → `pull --rebase` → push over HTTPS → Workers Builds
   builds, gates, deploys → app polls deployment status, streams the log, and on
   success runs the Webmention/POSSE post-deploy steps app-side (pure Swift + HTTP,
   fully portable — same code desktop runs today).

### C.5 Desktop flow

Unchanged core, plus the publish verbs: a post's editor and the navigator get
**Publish/Unpublish** (menu + toolbar, proper Mac conventions per the mac-assed spec);
publish commits then triggers whichever `PublishPipeline` the site is configured for.
The container path's dev-server preview keeps showing drafts (dev mode renders
`draft: true` entries with a "Draft" badge — dev-only, filtered from builds).

### C.6 Workers Builds provisioning

Connecting a Cloudflare account to the git host is a one-time dashboard OAuth step that
cannot be done headlessly; the app deep-links the user through it, then creates/updates
the build configuration (build command, deploy command, root directory) via the API and
verifies with a status poll. Exact API coverage for build-config creation is an open
item to verify during implementation (same manual-verify posture as #207's token
onboarding). Fallback if the API gap is real: the app shows copy-paste build settings
and verifies by observing the first deployment.

## Data flow

```
                    ┌── macOS (container) ────────────────────────────────┐
 edit (MarkdownTextView)                                                  │
   → save → commit (SwiftGit2)                                            │
   → Publish: draft:false + commit ──► ContainerPublishPipeline           │
                                        build → scan ✗→ blocked UI        │
                                        └─► wrangler deploy → URL         │
                                        └─► push origin (background)      │
                    └──────────────────────────────────────────────────────┘
                    ┌── iOS / container-less ─────────────────────────────┐
 edit local clone (MarkdownTextView)                                      │
   → save → commit (SwiftGit2, offline-safe)                              │
   → Publish: draft:false + commit → pull --rebase → push origin          │
       └─► Workers Builds (user's CF acct): npm run build:ci              │
             build → pre-deploy-check --strict ✗→ deploy never runs       │
             └─► wrangler deploy → app polls status + streams log         │
                  └─► app-side Webmention/POSSE on success                │
                    └──────────────────────────────────────────────────────┘
```

## Error handling & edge cases

- **Non-fast-forward push** → automatic `pull --rebase`; on conflict, a per-file
  keep-mine/keep-theirs sheet scoped to content files (the same conflict posture as
  `FileEditorModel`'s external-change flow). Never silent merge, never force-push.
- **CI build failure** → distinguish gate-blocked (scan envelope found in the log →
  existing blocked-deploy UI with categories/remediation) from plain build errors (log
  excerpt + link to full log). A failed CI deploy leaves the previous deploy live —
  static hosting's natural atomicity.
- **Draft leakage backstop** → optional pre-deploy-check addition: fail if any
  `draft: true` source entry has a corresponding page in `dist/` (cheap route check;
  belt-and-suspenders on top of route/feed filtering).
- **Schema errors authored on mobile** (no `astro check` locally) → surface at CI with
  the file/line from Astro's error output; mitigated up front because the form editor +
  registry constrain typed fields to valid shapes.
- **Offline** → editing and committing fully work; Publish is disabled with an explicit
  "waiting for network" state, never queued silently.
- **Missing prerequisites** → no `origin` → route to Publish-to-GitHub onboarding
  (desktop) or "open this site on your Mac first" guidance (iOS); missing/invalid CF or
  git token → the existing verify-then-persist reconnect flows.
- **Concurrent editing** (Mac + phone) → git handles it; per-edit commits keep changes
  small and rebases clean. The phone pulls on foreground/site-open, the Mac's checkout
  hydrates as today.

## Testing

- **`AnglesiteMarkdown` (unit, runs on Linux lane):** golden tests scanner → runs for
  every v1 construct; incremental-restyle equivalence (edited-region restyle ==
  full-document restyle); checkbox toggle produces exactly the 1-char edit; degenerate
  inputs (unclosed fences, 10k-line file) don't hang.
- **Editor round-trip:** typing/styling never mutates the buffer (byte-identity after
  an edit-free open/close); `TypedEntryEditorModel` save path unchanged.
- **Draft model:** template fixture tests — `draft: true` entry emits no `dist/` page,
  no index/feed entry, for each post-family collection; `swift test` template-coupled
  suites updated (`.strict()` schema additions).
- **`GitPushPublishPipeline` (unit):** faked git + faked Workers Builds client — happy
  path, non-FF → rebase, conflict surfaced, CI blocked-envelope parsed, CI plain
  failure, offline. Same style as `RemoteSandboxSiteRuntime`'s faked control client.
- **`build:ci` producer test:** fresh scaffold, seeded PII blocker → `npm run build:ci`
  exits non-zero *after* building; clean scaffold exits zero (extends the #742
  producer→consumer fixture lane).
- **One opt-in live e2e** (gated like the container/e2e suites): push a draft-flip
  commit to a real repo wired to Workers Builds, poll to deployed, assert the post URL
  is live.

## Phasing

1. **Slice 1 — editor on macOS:** `AnglesiteMarkdown` + `MarkdownTextView` +
   `.markdown` routing; Format menu + Find (#517). No behavior change to saving.
2. **Slice 2 — draft/publish model:** template schema + filtering, registry `draft`,
   drafts-by-default, desktop Publish/Unpublish verbs over the existing container
   pipeline.
3. **Slice 3 — push-to-deploy on desktop:** `PublishPipeline` seam, `build:ci` gate,
   Workers Builds client + onboarding, log streaming. Proves the container-less
   pipeline where debugging is easy.
4. **Slice 4 — mobile:** iOS shell grows the local-checkout mode (clone/pull/push via
   SwiftGit2), ported typed/markdown editors, mobile publish UX. Depends on #71 scope
   decisions.

Each slice is deterministic Swift/TypeScript end-to-end (no LLM path), per the #459
direction.

## Out of scope

- WYSIWYG rich-text editing that rewrites Markdown; the Component Editor (#496) owns
  visual editing of components.
- Media/photo posting pipeline from mobile (image import + asset commits) — the seam
  exists (`image` fields, git), but the capture/compression UX is its own design.
- Micropub as the mobile posting protocol — deliberately *not* chosen here (server-side
  Micropub is V-3, gated on `@dwk/workers`; this design needs no server component
  beyond CI). Revisit posting-via-Micropub when V-3 lands.
- Tables/LaTeX/wiki-link editor affordances; inline image thumbnails (fast-follow).
- Merging the template `blog` collection with typed `articles` (open question below).

## Open questions (owner input wanted)

1. **Workers Builds API surface** — can the build config be created purely via API
   once the GitHub↔Cloudflare connection exists? (Determines how hands-off §C.6 is.)
2. **`blog` vs `articles`** — keep both (blog = simple starter, articles = typed
   h-entry) or migrate the starter to `articles` and retire `blog`?
3. **iOS product shape** — does the container-less local-checkout mode *replace* the
   remote-sandbox thin client as the default iOS experience (sandbox becomes the
   "power preview" opt-in), or ship alongside it from day one? This spec assumes the
   former.
4. **swift-markdown-engine adoption** — if the in-house styler's macOS feel lags the
   reference, is a scoped adoption of SwiftMarkdownEngine behind the `MarkdownTextView`
   seam (macOS only, new-dep approval) acceptable as a stopgap?
