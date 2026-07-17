# Blog-post Markdown editor + container-less publishing — design

**Date:** 2026-07-17
**Status:** Proposed (brainstorm output; needs owner sign-off before implementation)
**Related:** #517 (Find + Format menu, blocked on editor work) · #288 (template blog system) · #346 (typed form editors) · #68 (repo bootstrap / Publish to GitHub) · #640/#654 (in-process git) · #742 (pre-deploy scan envelope) · #71/#66 (iOS thin client + remote sandbox) · #571 (cross-platform port) · epic #496 (Component Editor, STTextView precedent) · **#334 pivot: V-2 IndieAuth (#355), V-2.1 per-site Worker (#353), V-3 Micropub, V-3.4 snapshot-to-git (#362)** · C.2 workers seam + C.3 canonicality decision docs (2026-06-29)

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
   additionally require GitHub or any other git host. **Mobile posting is gated on the
   V-3 `@dwk/workers` conformance milestone and uses Micropub as the posting protocol**
   (owner decision, 2026-07-17) — the pivot's own standards-based posting API, rather
   than any bespoke Anglesite transport.

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

Two pivot decisions this design leans on directly: the **C.2 workers seam** (per-site
Cloudflare Worker composing `@dwk/*` packages — `@dwk/micropub` at `/micropub` in V-3 —
with `WorkersConformanceReader`/`gateStatus(for:)` already in AnglesiteCore to gate
feature enablement), and **C.3 canonicality** ("git-canonical, D1-operational": the
Worker's store is operational, git is the durable archive, reconciled by a
snapshot-to-git step — the V-3.4/#362 flow, with #587's inbox capture + `InboxSubmissionSync`
commit-back as the shipped precedent).

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

On every platform: **published content ends up as commits in `Source/` (directly on
desktop; via the C.3 snapshot for Micropub), and reaches the live site only through a
deterministic build whose pre-deploy security gate no client can skip, with build logs
surfaced** (logs are sacred). No LLM in the loop anywhere.

### C.2 Decision: mobile posting is Micropub, gated on V-3 workers

GitHub cannot be load-bearing anywhere in the required path, and (owner decision,
2026-07-17) **Anglesite does not invent its own container-less publishing transport
either**. The container-less posting protocol is **Micropub** — the W3C posting API
the Personal Publishing OS pivot (#334) already ships in V-3 as `@dwk/micropub` on the
per-site Worker (C.2 seam doc), authenticated by IndieAuth (V-2, #355). Mobile posting
is therefore **feature-gated on V-3 `@dwk/workers` conformance**, using the
`WorkersConformanceStatus.gateStatus(for:)` machinery that already exists for exactly
this purpose: until V-3's packages are release-ready, the app does not offer mobile
publishing (BBEdit-style honest labeling, not a silent degraded path).

Why Micropub and not a bespoke transport (or the 2000s posting APIs):

- **It's already on the roadmap** — building it for third-party clients and *not*
  using it for our own mobile client would mean maintaining two posting paths.
- **mf2-native** — Micropub's vocabulary (h-entry properties, `mp-slug`,
  `post-status`, media endpoint) maps 1:1 onto the content-type registry's h-entry
  projections; nothing is lossy for the post-family types.
- **Cloudflare-only holds** — the per-site Worker, D1, R2, and the self-hosted
  IndieAuth endpoint all live in the user's own Cloudflare account. No GitHub, no
  git host, no extra accounts.
- **Third-party clients come free** — any Micropub client (including modern MarsEdit)
  can post to the user's site through the same endpoint the Anglesite app uses.
- **MetaWeblog / AtomPub were considered and rejected** — both assume a server-side
  CMS that owns content (inverting #72's git canonicality), can't round-trip
  Markdown + YAML frontmatter byte-faithfully (XML-RPC HTML strings / Atom XML
  entries), have no typed-content or draft vocabulary matching the registry, and
  their client ecosystem has moved to Micropub anyway.

The `PublishPipeline` seam in AnglesiteCore then has two shapes:

- **`ContainerPublishPipeline`** (desktop) — the existing path, unchanged:
  `DeployCommand` runs build → pre-deploy scan (#742 envelope, `.blocked` is final) →
  `wrangler deploy` inside the container runtime. Fast local iteration, no server
  round-trip.
- **`MicropubClient`** (container-less; iOS, and any future thin client) — not a
  build pipeline at all: a typed client of the site's own `/micropub` endpoint
  (create / update / delete, `post-status` for drafts, media endpoint for images),
  with the Worker-side snapshot-to-git + bake closing the loop (§C.4).

### C.3 Moving the gate server-side (template change, app-only)

The template's CI story gets a `build:ci` script:

```jsonc
// Resources/Template/package.json
"build:ci": "npm run build && npx tsx scripts/pre-deploy-check.ts --json --strict"
```

`build:ci` is the single entry point for every non-interactive runner — whatever bake
substrate V-3 settles on (§C.4), and Workers Builds if a site happens to have a GitHub
mirror. The scan runs **after** the build (it inspects `dist/`, matching
`DeployCommand`'s ordering) and a blocker exits non-zero, so **the deploy step never
runs**. Micropub-authored content gets the same treatment: it only reaches the static
site through a bake, so the gate covers it with no special-casing — and Micropub input
is additionally constrained upstream by the typed vocabulary (no script injection
surface a form field wouldn't also have). The scan's `--json` envelope (#742) is
emitted into the build log; on failure the app extracts it when present and renders
the existing `Phase.blocked` UI, falling back to a raw log excerpt for ordinary build
errors.

### C.4 The Micropub data path (per-site Worker, user's Cloudflare account)

The server side is the pivot's per-site Worker (V-2.1, #353 — `@dwk/micropub` at
`/micropub`, IndieAuth at `/.well-known/indieauth`, D1 + R2 bindings), not anything
new this spec invents. What this spec pins down is how a Micropub post becomes site
content, following the **C.3 canonicality decision** ("git-canonical,
D1-operational") end to end:

1. **Accept (operational):** the Micropub endpoint validates the IndieAuth token,
   stores the post in D1 (media uploads → R2 via the media endpoint), and assigns the
   permalink from `mp-slug`/type rules. `post-status: draft` posts are stored but
   never rendered publicly.
2. **Snapshot to git (canonical):** the V-3.4 (#362) snapshot step serializes
   authored posts into `Source/src/content/<collection>/<slug>.md` — **full-fidelity
   Markdown + YAML frontmatter matching the registry schema** (unlike received
   interactions, which snapshot as truncated JSON; authored content is first-class),
   with `post-status` mapping onto Part B's `draft` field and R2 media committed as
   site assets. From that commit on, the post is ordinary content — editable in the
   Mac app, any git clone, or via Micropub `q=source` + update (which round-trips
   through the same snapshot).
3. **Bake:** the post reaches the *published* static site at the next build + deploy
   (`build:ci`, §C.3 — the gate always runs). What triggers a bake after a mobile
   post — the next desktop deploy, a Worker-triggered build substrate, or "fresh
   posts render dynamically until the next bake" via the ESI seam
   (`@dwk/esi` + the 2026-07-13 ESI components) — is a **V-3 epic decision, not
   re-decided here** (open question 1). This spec only requires that some bake path
   exists and that drafts never reach `dist/`.

The app-side precedent for step 2's commit-back is shipped code: #587's
`InboxSubmissionSync` (Worker staging → app-side git commit). Whether V-3.4's
snapshot commits Worker-side or app-side follows that epic's design; either way the
phone itself never touches git — **mobile needs no local clone, no SwiftGit2, no
push credentials**, which is the big simplification Micropub buys over any git-based
mobile transport.

### C.5 Mobile flow end-to-end (no containers on the device, Cloudflare only)

**Prerequisites:** the site's per-site Worker is provisioned with V-2/V-3 features
enabled (§C.7), and `WorkersConformanceStatus.gateStatus(for:)` reports V-3 ready —
otherwise mobile publishing is not offered at all (clearly labeled as requiring the
site's social features, never a silent failure).

1. **Onboarding (once):** enter the site URL → the app discovers the `micropub` +
   IndieAuth endpoints from the site's own markup/well-knowns (standard Micropub
   client discovery) → IndieAuth sign-in (`ASWebAuthenticationSession`; the user
   authenticates against *their own site*) → token in the Keychain. No GitHub, no
   git credentials, no clone.
2. **Compose:** `MarkdownTextView` (Part A) as the body surface plus the
   registry-driven typed fields (Part B's schema, rendered with the
   `TypedEntryEditorView` control mapping ported to iOS idioms —
   `PhotosPicker`/`fileImporter` instead of `NSOpenPanel`). Offline composing works;
   unsent posts persist locally as queued drafts and are labeled as *local* drafts
   (distinct from server-side `post-status: draft`).
3. **Post / draft:** submit via Micropub — `post-status: draft` for drafts,
   `mp-slug` derived the same way `NativeContentOperations` derives slugs, media
   through the media endpoint to R2. Editing an existing post = `q=source` fetch →
   edit → Micropub update; the snapshot step (§C.4) round-trips it into git.
4. **Publish:** flip the post to published (Micropub update of `post-status`) → the
   Worker snapshot + bake path takes over (§C.4); the app reflects the state honestly
   ("published — goes live with the next site build" until the bake confirms, then
   the live URL). Webmention/POSSE for micropub-authored posts ride V-3's
   server-side machinery rather than the app-side desktop commands.

There is **no fake local preview** — rendering Markdown to HTML app-side would be a
second Markdown implementation diverging from Astro's, shown in site-unlike CSS. The
styled editor is the draft surface; the deployed site is the truth.

### C.6 Desktop flow

Unchanged core, plus the publish verbs: a post's editor and the navigator get
**Publish/Unpublish** (menu + toolbar, proper Mac conventions per the mac-assed spec);
publish commits then triggers whichever `PublishPipeline` the site is configured for.
The container path's dev-server preview keeps showing drafts (dev mode renders
`draft: true` entries with a "Draft" badge — dev-only, filtered from builds).

### C.7 Provisioning (V-2.1, reused as-is)

Nothing new: enabling mobile publishing for a site *is* enabling the site's social
features — the V-2.1 (#353) provisioning sequence run from the desktop app (existing
`keychainTokenSource` token → D1 database → R2 bucket → `wrangler.toml` bindings →
`worker/worker.ts` composition with `@dwk/micropub` + IndieAuth enabled → deploy).
All of it is against the user's own Cloudflare account; the conformance gate
(`workers-version.json` + `gateStatus(for:)`) decides when the app offers it. If the
user later runs Publish to GitHub (#68), that remains an optional mirror; nothing in
this path references a git host.

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
                    ┌── iOS / container-less (Micropub, gated on V-3) ────┐
 compose (MarkdownTextView + typed fields, offline-queued)                │
   → Micropub create/update (post-status: draft|published,               │
       │   media → R2)  [IndieAuth token, user's own site]                │
       └─► per-site Worker: D1 (operational store)                        │
             └─► V-3.4 snapshot → Source/src/content/<coll>/<slug>.md     │
                   (git canonical; draft ⇄ post-status)                   │
             └─► bake: npm run build:ci                                   │
                   build → pre-deploy-check --strict ✗→ deploy never runs │
                   └─► deploy → post live; app reflects state             │
                    └──────────────────────────────────────────────────────┘
```

## Error handling & edge cases

- **Conformance gate not met** → mobile publishing simply isn't offered; the UI names
  the requirement ("needs this site's social features — V-3") rather than degrading.
  `gateStatus(for:)` is checked at feature-surface time, not buried in a failed post.
- **Micropub request failures** → endpoint unreachable / 5xx → the post stays a local
  queued draft with explicit retry; 401/403 → IndieAuth re-auth flow
  (verify-then-persist posture, matching `TokenOnboarding`); validation errors from
  the endpoint → surfaced against the offending field (the typed form knows which one).
- **Offline** → composing and local drafts fully work; sending is disabled with an
  explicit "waiting for network" state; queued posts are visibly queued, never
  silently held.
- **Snapshot/bake lag** → an accepted post that hasn't baked yet shows as
  "published — awaiting site build," with the D1-accepted state as evidence; the app
  never fakes a live URL before the bake confirms it.
- **Bake build failure** → distinguish gate-blocked (scan envelope → existing
  blocked-deploy UI with categories/remediation) from plain build errors (log excerpt
  + full log). A failed bake leaves the previous deploy live — static hosting's
  natural atomicity.
- **Draft leakage backstop** → optional pre-deploy-check addition: fail if any
  `draft: true` source entry (or unsnapshotted `post-status: draft` record) has a
  corresponding page in `dist/` (cheap route check; belt-and-suspenders on top of
  route/feed filtering).
- **Concurrent editing** (Mac edits the file, phone edits via Micropub) → C.3's rule
  applies: the snapshot is idempotent and **git wins on divergence**; a Micropub
  update against a post whose file changed since its last snapshot is rejected with a
  refresh (`q=source` re-fetch) rather than silently clobbering the git-side edit.
- **Media constraints** → media-endpoint upload failures and R2 size limits surface
  per-attachment with retry; a post never partially publishes with missing media.

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
- **`MicropubClient` (unit, AnglesiteCore):** faked endpoint — create/update/delete,
  `post-status` draft⇄published, `mp-slug` derivation matches
  `NativeContentOperations` slugs, media-endpoint flow, `q=source` round-trip,
  401 → re-auth, 5xx → queued retry, offline queue. Same faked-seam style as
  `RemoteSandboxSiteRuntime`'s `SandboxControlClient` tests.
- **Conformance gating (unit):** feature surface hidden/shown correctly from
  `WorkersConformanceStatus` fixtures (machinery already exists; these tests cover
  the new consumer).
- **Snapshot fidelity (cross-repo, V-3.4's suite + a fixture here):** a Micropub
  create/update serializes to Markdown + frontmatter that parses back through
  `FrontmatterDocument`/the registry schema losslessly, and `post-status` maps to
  `draft` exactly.
- **`build:ci` producer test:** fresh scaffold, seeded PII blocker → `npm run build:ci`
  exits non-zero *after* building; clean scaffold exits zero (extends the #742
  producer→consumer fixture lane).
- **One opt-in live e2e** (gated like the container/e2e suites, real Cloudflare
  account, once V-3 packages exist): provision a site's Worker, post via Micropub,
  assert D1 accept → git snapshot → post-bake live URL, and that a draft never
  appears in `dist/`.

## Phasing

1. **Slice 1 — editor on macOS:** `AnglesiteMarkdown` + `MarkdownTextView` +
   `.markdown` routing; Format menu + Find (#517). No behavior change to saving.
2. **Slice 2 — draft/publish model:** template schema + filtering, registry `draft`,
   drafts-by-default, desktop Publish/Unpublish verbs over the existing container
   pipeline.
3. **Slice 3 — `build:ci` + bake groundwork:** the template `build:ci` script and
   envelope-from-log parsing, exercised by the desktop pipeline now so the gate
   contract is proven before any server-side runner consumes it.
4. **Slice 4 — mobile Micropub client** *(gated on V-3 `@dwk/workers` conformance —
   blocked until that milestone is green, like every V-3 feature)*: `MicropubClient`
   in AnglesiteCore, IndieAuth onboarding, iOS compose UI (ported typed/markdown
   editors), post/draft/publish flows. The snapshot-to-git and bake-trigger work is
   V-3.4's (#362), not this spec's — slice 4 consumes it.

Slices 1–3 have no dependency on the workers repo and can land now; slice 4 is the
gated feature.

Each slice is deterministic Swift/TypeScript end-to-end (no LLM path), per the #459
direction.

## Out of scope

- WYSIWYG rich-text editing that rewrites Markdown; the Component Editor (#496) owns
  visual editing of components.
- Media/photo posting *UX* from mobile — the transport is settled (Micropub media
  endpoint → R2 → committed as assets at snapshot), but capture/compression/alt-text
  UX is its own design.
- **Git as the mobile transport** — an earlier revision of this spec designed a
  phone-side SwiftGit2 clone pushing to a bespoke R2-backed git origin + build
  sandbox in the user's Cloudflare account. Superseded by the Micropub decision
  (§C.2): it duplicated the posting API the pivot already ships, required paid-plan
  containers, and put git plumbing on the phone for no user-visible gain. Desktop
  git workflows are untouched; only the *mobile transport* changed.
- MetaWeblog / AtomPub — rejected, rationale recorded in §C.2.
- Workers Builds for GitHub-mirrored repos — optional follow-on, never the default.
- Tables/LaTeX/wiki-link editor affordances; inline image thumbnails (fast-follow).
- Merging the template `blog` collection with typed `articles` (open question below).

## Open questions (owner input wanted)

1. **Bake trigger after a mobile post** (V-3 epic decision, flagged here): next
   desktop deploy only, a Worker-triggered build substrate, or fresh posts rendered
   dynamically until the next bake via the ESI seam (`@dwk/esi` + the 2026-07-13 ESI
   components)? This spec only requires *some* bake path with the gate in it.
2. **Snapshot commit-back locus for a mobile-only user** — #587's precedent commits
   app-side (a Mac pulls staged submissions into git). If no Mac opens for weeks,
   micropub posts live only in D1 (operational) — is that acceptable interim state,
   or does V-3.4 need a Worker-side commit path (which reopens the "what repo can the
   Worker push to without GitHub" question)?
3. **`blog` vs `articles`** — keep both (blog = simple starter, articles = typed
   h-entry) or migrate the starter to `articles` and retire `blog`?
4. **iOS product shape** — is the Micropub client the *whole* default iOS experience
   (with the remote-sandbox thin client as the "power preview" opt-in), or do they
   ship together? This spec assumes the former.
5. **swift-markdown-engine adoption** — if the in-house styler's macOS feel lags the
   reference, is a scoped adoption of SwiftMarkdownEngine behind the `MarkdownTextView`
   seam (macOS only, new-dep approval) acceptable as a stopgap?
