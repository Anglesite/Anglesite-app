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
   assumed to have **no container access on the device** — no Apple Containerization,
   no Node, no subprocesses; the phone only makes HTTPS calls — and where **Cloudflare
   is the only required third-party dependency** (owner decision, 2026-07-17). The user
   already needs a Cloudflare account to host the site; publishing must not
   additionally require GitHub or any other git host.

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

### C.2 One seam, two strategies — Cloudflare-only by requirement

GitHub cannot be load-bearing anywhere in the required path. That rules out Cloudflare
Workers Builds as the container-less pipeline — Workers Builds only connects to
GitHub/GitLab repos, so a design built on it silently reintroduces a git-host account
as a prerequisite. Instead, the container-less path runs entirely against services in
the **user's own Cloudflare account** (§C.4). GitHub stays what it already is via
RepoBootstrap (#68): an optional mirror/collaboration surface, never a requirement.

A `PublishPipeline` protocol in AnglesiteCore with two implementations:

- **`ContainerPublishPipeline`** — the existing desktop path, unchanged:
  `DeployCommand` runs build → pre-deploy scan (#742 envelope, `.blocked` is final) →
  `wrangler deploy` inside the container runtime. Fast local iteration, no push
  required.
- **`CloudPublishPipeline`** — the container-less path: commit → pull
  (fast-forward/rebase) → push to the site's **Anglesite-provisioned git origin in the
  user's Cloudflare account** (§C.4) → the origin's publish service builds, gates, and
  deploys in an ephemeral Cloudflare Sandbox → the app polls the control Worker for
  status and streams the build log into the debug pane.

Mobile only has the second. Desktop gets both — push-to-publish is also the natural fit
for the Linux/Windows ports (#571) and for users who never provision the container
runtime. `DeployModel` picks the strategy the way it picks `ContainerDeployExecutor`
today.

**Optional Workers Builds variant:** when a site *does* have a GitHub remote (the user
ran Publish to GitHub), Workers Builds can drive the same `build:ci` entry point (§C.3)
off pushes to that remote. Nice-to-have, not v1-required, and never the default.

### C.3 Moving the gate server-side (template change, app-only)

The template's CI story gets a `build:ci` script:

```jsonc
// Resources/Template/package.json
"build:ci": "npm run build && npx tsx scripts/pre-deploy-check.ts --json --strict"
```

`build:ci` is the single server-side entry point: the publish service (§C.4) runs it,
and so does the optional Workers Builds variant when a GitHub remote exists. The scan
runs **after** the build (it inspects `dist/`, matching `DeployCommand`'s ordering) and
a blocker exits non-zero, so **the deploy step never runs**. This is strictly stronger
than today's posture: the gate becomes unbypassable from *any* client — the app, a
laptop with `git push`, or a compromised device — rather than being enforced by app
code. The desktop container path keeps its local preflight too (better UX: blocked
before pushing anything). The scan's `--json` envelope (#742) is emitted into the build
log; on failure the app extracts it when present and renders the existing
`Phase.blocked` UI, falling back to a raw log excerpt for ordinary build errors.

### C.4 The git origin + publish service (user's Cloudflare account)

The piece that removes GitHub from the requirements: a small, Anglesite-maintained
**site-services Worker** the user deploys into their own account **once**, via the
Deploy-to-Cloudflare button — the same provisioning shape (and plausibly the same
template repo) as the 2026-06-23 remote-sandbox design. It provides, per site:

- **A durable git origin.** Bare repos live in **R2**; a per-site Durable Object owns
  each one. Serving uses *real git*, not a pack-protocol reimplementation in Workers
  JS: the control Worker wakes an ephemeral Sandbox that restores the bare repo from
  R2 and serves **git smart HTTP** (`git http-backend`) behind the token-checking auth
  proxy; after a push, the repo syncs back to R2 *before* the push is reported
  successful. Because it speaks standard smart HTTP with a token, any git client can
  clone and push it — #72's "clonable anywhere" invariant holds with zero GitHub
  involvement.
- **The publish pipeline.** A push to the origin (or an explicit publish RPC) makes
  the service check out the pushed ref in the sandbox, run `npm run build:ci` (§C.3 —
  build, then the pre-deploy gate), and on success `wrangler deploy` in-sandbox with
  the account's token. The control Worker exposes status + build logs for the app to
  poll and stream (logs are sacred, on every platform).

Boundaries and posture:

- This sandbox is **ephemeral compute in the user's Cloudflare account, not a
  container on the device** — the phone still only makes HTTPS calls, so the
  no-containers-on-mobile constraint holds. It is distinct from the remote *preview*
  sandbox (#66), which stays an opt-in live dev-server session; the publish sandbox
  runs for seconds-to-minutes per publish, then sleeps. Disk loss on sleep is
  immaterial — R2 is the durable home and the sandbox is always reconstructable from
  it (the same cold-hydrate posture #66 already accepted).
- **Single-writer safety:** the per-site DO serializes pushes; the R2 sync completes
  before receive-pack's response is released, so a crash mid-push means the client
  re-pushes — the R2 copy is never a torn state.
- **Billing honesty:** Cloudflare Sandboxes/Containers require the Workers paid plan.
  That is a real cost floor for container-less publishing, but it is a *Cloudflare*
  cost on the account the user already bills for hosting — consistent with the BYO
  "user bills, zero Anglesite-operated infra" posture. Surfaced plainly in onboarding,
  never a silent failure.

### C.5 Mobile flow end-to-end (no containers on the device, Cloudflare only)

**Prerequisite:** the site has its Cloudflare origin (§C.4) — set up from any device
that has the site, typically the Mac, which pushes `Source/` to the origin when
cloud publishing is enabled. A site that exists only on one Mac's disk is not
reachable from a phone *by design* (git is the sync layer; there is no bespoke
Anglesite sync protocol — the origin just lives in the user's Cloudflare account
instead of on a git host).

1. **Onboarding (once):** connect Cloudflare with the existing verify-then-persist
   `TokenOnboarding` pattern; provision the site-services Worker via the
   Deploy-to-Cloudflare button (§C.7); pick the site and **shallow clone** `Source/`
   from its origin into the app's container directory via SwiftGit2 (libgit2 is
   already the Darwin git path; no subprocess involved). No GitHub sign-in exists in
   this flow.
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
4. **Publish:** flip draft (§B.3) → `pull --rebase` → push to the origin → the publish
   service builds, gates, deploys (§C.4) → app polls status, streams the log, and on
   success runs the Webmention/POSSE post-deploy steps app-side (pure Swift + HTTP,
   fully portable — same code desktop runs today).

Creating a *new* site from the phone is feasible under this design (the template is an
app resource; scaffold + `git init` + push to a fresh origin need no Node — `npm ci`
happens server-side in `build:ci`), but it is a follow-on, not part of this slice.

### C.6 Desktop flow

Unchanged core, plus the publish verbs: a post's editor and the navigator get
**Publish/Unpublish** (menu + toolbar, proper Mac conventions per the mac-assed spec);
publish commits then triggers whichever `PublishPipeline` the site is configured for.
The container path's dev-server preview keeps showing drafts (dev mode renders
`draft: true` entries with a "Draft" badge — dev-only, filtered from builds).

### C.7 Provisioning (one-time, Cloudflare only)

Two steps, both against Cloudflare and nothing else:

1. **API token** — the existing verify-then-persist `TokenOnboarding` flow
   (Keychain-stored, verified before use), with scopes extended to cover the
   site-services Worker's needs (Workers scripts, DO, R2).
2. **Site-services Worker** — deployed into the user's account via the
   Deploy-to-Cloudflare button against the Anglesite template repo (browser OAuth to
   *Cloudflare*, hosted build — the exact mechanism the remote-sandbox design already
   locked, because a phone can't run wrangler or build images). The app then verifies
   with a status RPC and registers the site's origin URL.

Per-site enablement afterward is a single control-Worker call (create the DO + R2
prefix + origin URL). If the user later runs Publish to GitHub (#68), that adds a
mirror remote and unlocks the optional Workers Builds variant; nothing in the required
path changes.

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
                    ┌── iOS / container-less (Cloudflare only) ───────────┐
 edit local clone (MarkdownTextView)                                      │
   → save → commit (SwiftGit2, offline-safe)                              │
   → Publish: draft:false + commit → pull --rebase                        │
   → push → git origin (user's CF acct: DO + R2 bare repo,                │
       │     smart HTTP via git http-backend in ephemeral sandbox)        │
       └─► publish service (same sandbox): npm run build:ci               │
             build → pre-deploy-check --strict ✗→ deploy never runs       │
             └─► wrangler deploy → app polls status + streams log         │
                  └─► app-side Webmention/POSSE on success                │
                    └──────────────────────────────────────────────────────┘
```

## Error handling & edge cases

- **Non-fast-forward push** → automatic `pull --rebase`; on conflict, a per-file
  keep-mine/keep-theirs sheet scoped to content files (the same conflict posture as
  `FileEditorModel`'s external-change flow). Never silent merge, never force-push.
- **Pipeline build failure** → distinguish gate-blocked (scan envelope found in the log
  → existing blocked-deploy UI with categories/remediation) from plain build errors
  (log excerpt + link to full log). A failed pipeline run leaves the previous deploy
  live — static hosting's natural atomicity.
- **Cold starts** → pushing/publishing may wake the sandbox; the publish UI shows
  determinate-ish states (waking → pushing → building → checking → deploying), the
  same progress posture as #66's `.starting`.
- **Draft leakage backstop** → optional pre-deploy-check addition: fail if any
  `draft: true` source entry has a corresponding page in `dist/` (cheap route check;
  belt-and-suspenders on top of route/feed filtering).
- **Schema errors authored on mobile** (no `astro check` locally) → surface at CI with
  the file/line from Astro's error output; mitigated up front because the form editor +
  registry constrain typed fields to valid shapes.
- **Offline** → editing and committing fully work; Publish is disabled with an explicit
  "waiting for network" state, never queued silently.
- **Missing prerequisites** → no Cloudflare origin → route to site-services
  provisioning (§C.7) on desktop, or "enable cloud publishing on your Mac first"
  guidance on iOS; missing/invalid token → the existing verify-then-persist reconnect
  flows; Workers plan lacks container support → explicit upgrade guidance, never a
  silent retry loop.
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
- **`CloudPublishPipeline` (unit):** faked git + faked site-services control client —
  happy path, non-FF → rebase, conflict surfaced, blocked-envelope parsed, plain build
  failure, offline, cold-start states. Same style as `RemoteSandboxSiteRuntime`'s
  faked `SandboxControlClient`.
- **Site-services Worker (its own repo's suite):** origin round-trip — clone/push
  against the served smart HTTP with a stock git client; push → R2 sync ordering;
  DO-serialized concurrent pushes; publish RPC drives `build:ci` and reports the
  envelope.
- **`build:ci` producer test:** fresh scaffold, seeded PII blocker → `npm run build:ci`
  exits non-zero *after* building; clean scaffold exits zero (extends the #742
  producer→consumer fixture lane).
- **One opt-in live e2e** (gated like the container/e2e suites, real Cloudflare
  account): provision, push a draft-flip commit to the origin, poll to deployed,
  assert the post URL is live and a re-clone of the origin matches the local repo.

## Phasing

1. **Slice 1 — editor on macOS:** `AnglesiteMarkdown` + `MarkdownTextView` +
   `.markdown` routing; Format menu + Find (#517). No behavior change to saving.
2. **Slice 2 — draft/publish model:** template schema + filtering, registry `draft`,
   drafts-by-default, desktop Publish/Unpublish verbs over the existing container
   pipeline.
3. **Slice 3 — Cloudflare publish services + desktop push-to-publish:** the
   site-services Worker (git origin + publish pipeline, its own template repo),
   `PublishPipeline` seam, `build:ci` gate, provisioning + log streaming in the Mac
   app. Proves the whole container-less pipeline where debugging is easy — the phone
   adds no new moving parts server-side.
4. **Slice 4 — mobile:** iOS shell grows the local-checkout mode (clone/pull/push via
   SwiftGit2 against the Cloudflare origin), ported typed/markdown editors, mobile
   publish UX. Depends on #71 scope decisions.

Each slice is deterministic Swift/TypeScript end-to-end (no LLM path), per the #459
direction.

## Out of scope

- WYSIWYG rich-text editing that rewrites Markdown; the Component Editor (#496) owns
  visual editing of components.
- Media/photo posting pipeline from mobile (image import + asset commits) — the seam
  exists (`image` fields, git), but the capture/compression UX is its own design.
- Micropub as the mobile posting protocol — deliberately *not* chosen here (server-side
  Micropub is V-3, gated on `@dwk/workers`; this design's only server component is the
  site-services Worker, which is git + build, not a posting API). Revisit
  posting-via-Micropub when V-3 lands.
- The Workers Builds variant for GitHub-mirrored repos (§C.2) — optional follow-on.
- Tables/LaTeX/wiki-link editor affordances; inline image thumbnails (fast-follow).
- Merging the template `blog` collection with typed `articles` (open question below).

## Open questions (owner input wanted)

1. **Site-services template home** — its own repo, or folded into the #66
   remote-sandbox Deploy-to-Cloudflare template so one provisioning pass yields one
   "Anglesite Cloud" Worker offering both preview sessions and origin/publish? (One
   template is friendlier; one repo per concern is simpler to version.)
2. **`blog` vs `articles`** — keep both (blog = simple starter, articles = typed
   h-entry) or migrate the starter to `articles` and retire `blog`?
3. **iOS product shape** — does the container-less local-checkout mode *replace* the
   remote-sandbox thin client as the default iOS experience (sandbox becomes the
   "power preview" opt-in), or ship alongside it from day one? This spec assumes the
   former.
4. **swift-markdown-engine adoption** — if the in-house styler's macOS feel lags the
   reference, is a scoped adoption of SwiftMarkdownEngine behind the `MarkdownTextView`
   seam (macOS only, new-dep approval) acceptable as a stopgap?
5. **Workers paid-plan floor** — is requiring the paid plan for container-less
   publishing acceptable for v1, or does that justify prioritizing the Workers Builds
   variant (free tier, but GitHub-gated) as a cost fallback for users who *choose* a
   GitHub mirror?
