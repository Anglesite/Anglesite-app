# Blog-post Markdown editor + container-less publishing — design

**Date:** 2026-07-17
**Status:** Proposed; owner decisions locked 2026-07-17 during review: (1) mobile
posting is Micropub, gated on V-3 `@dwk/workers` conformance; (2) bakes are
**Worker-triggered**; (3) **Cloudflare is canonical for typed content** ("headless
CMS" model) — this deliberately **re-scopes #72 and reverses C.3's canonicality**,
for authored content and (4, unified) for received interactions too (git stays
canonical for code/theme; content portability becomes a guaranteed continuous
export-to-git); (5) the V-3 Worker API includes a **bulk content read endpoint** for
builds; (6) **export is desktop-only** — mobile has no export path. Cross-cutting
(#340-class); flagged here so the reversals are explicit, not absorbed.
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

Two pivot artifacts this design leans on directly: the **C.2 workers seam** (per-site
Cloudflare Worker composing `@dwk/*` packages — `@dwk/micropub` at `/micropub` in V-3 —
with `WorkersConformanceReader`/`gateStatus(for:)` already in AnglesiteCore to gate
feature enablement), and **C.3's snapshot mechanism** (D1 → markdown/JSON files → git).
C.3's *canonicality* ruling is reversed for authored content by this spec (owner
decision — see Status): the snapshot machinery survives, demoted from "git is canon"
to "git receives a guaranteed continuous export."

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

Mode note: everything above is the literal mechanism for **un-provisioned (all-git)
sites**. In CMS mode (§C.4), the same registry `draft` field and publish semantics
apply, but the state lives as Micropub `post-status` on the canonical record, the
loader filters drafts server-side, and exports write the `draft` frontmatter — one
vocabulary, two storage homes.

## Part C — the publish pipelines

### C.1 Invariant

On every platform: **typed content is canonical in the user's own Cloudflare account
(D1/R2 behind the per-site Worker) once a site's publishing features are provisioned,
git remains canonical for code/theme, content is continuously exportable to git, and
nothing reaches the live site except through a deterministic build whose pre-deploy
security gate no client can skip, with build logs surfaced** (logs are sacred). No LLM
in the loop anywhere. Un-provisioned sites keep today's all-git file model unchanged —
Cloudflare-canonical content is what enabling the publishing features *means*.

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
- **MetaWeblog / AtomPub were considered and rejected** — they can't round-trip
  Markdown + typed frontmatter faithfully (XML-RPC HTML strings / Atom XML entries),
  have no typed-content or draft vocabulary matching the registry, carry weak auth
  stories next to IndieAuth, and their client ecosystem has moved to Micropub
  anyway. (Their "server owns the content" shape is no longer the objection — the
  CMS model adopts it — but the protocol itself is the wrong vocabulary.)

The `PublishPipeline` seam in AnglesiteCore then has two shapes:

- **`ContainerPublishPipeline`** (desktop) — the existing path, unchanged:
  `DeployCommand` runs build → pre-deploy scan (#742 envelope, `.blocked` is final) →
  `wrangler deploy` inside the container runtime. Fast local iteration, no server
  round-trip.
- **`MicropubClient`** (container-less; iOS, any future thin client, and the desktop
  app itself for provisioned sites) — not a build pipeline at all: a typed client of
  the site's own `/micropub` endpoint (create / update / delete, `post-status` for
  drafts, media endpoint for images), with the Worker-triggered bake and the
  export-to-git step closing the loop (§C.4).

### C.3 Moving the gate server-side (template change, app-only)

The template's CI story gets a `build:ci` script:

```jsonc
// Resources/Template/package.json
"build:ci": "npm run build && npx tsx scripts/pre-deploy-check.ts --json --strict"
```

`build:ci` is the single entry point for every non-interactive runner — the
Worker-triggered bake container (§C.4), and Workers Builds if a site happens to have a
GitHub mirror. The scan runs **after** the build (it inspects `dist/`, matching
`DeployCommand`'s ordering) and a blocker exits non-zero, so **the deploy step never
runs**. Micropub-authored content gets the same treatment: it only reaches the static
site through a bake, so the gate covers it with no special-casing — and Micropub input
is additionally constrained upstream by the typed vocabulary (no script injection
surface a form field wouldn't also have). The scan's `--json` envelope (#742) is
emitted into the build log; on failure the app extracts it when present and renders
the existing `Phase.blocked` UI, falling back to a raw log excerpt for ordinary build
errors.

### C.4 The CMS data path (per-site Worker, user's Cloudflare account)

The server side is the pivot's per-site Worker (V-2.1, #353 — `@dwk/micropub` at
`/micropub`, IndieAuth at `/.well-known/indieauth`, D1 + R2 bindings). Under the
Cloudflare-canonical model, a post's life is:

1. **Accept (canonical):** the Micropub endpoint validates the IndieAuth token,
   stores the post in D1 (media → R2 via the media endpoint), and assigns the
   permalink from `mp-slug`/type rules. **D1 acceptance *is* canonicality** — there
   is no downstream commit the post is waiting on. `post-status: draft` posts are
   stored but never rendered publicly.
2. **Bake (Worker-triggered — owner decision, 2026-07-17):** on a publish-affecting
   write, the control Worker starts an ephemeral **build container** (same compute
   family as #66's sandbox; requires the Workers paid plan — surfaced in onboarding,
   never a silent failure) that assembles the site and runs `build:ci` (§C.3 — the
   gate always runs), then deploys. Rapid consecutive posts coalesce (debounced
   rebuild), and the ESI seam (`@dwk/esi` + the 2026-07-13 components) remains an
   optimization for showing fresh content between bakes, not a requirement.
3. **Export to git (portability guarantee):** C.3's snapshot machinery, demoted from
   canon to **continuous export**: authored posts serialize to full-fidelity
   Markdown + YAML frontmatter (registry schema; `post-status` ⇄ Part B's `draft`)
   with R2 media alongside. **Received interactions unify under the same model**
   (owner decision, 2026-07-17): D1-canonical, exported to
   `Source/data/interactions/` in C.3's JSON shape — one canonicality rule for
   everything the Worker stores, superseding C.3's git-canonical ruling for them.
   The desktop app syncs exports down into `Source/` (one-way, the #587
   `InboxSubmissionSync` shape) and **File ▸ Export** always yields a complete
   site — code *and* content — so the site outlives Cloudflare. **Export is
   desktop-only** (owner decision, 2026-07-17): mobile is a posting client, not an
   archival one — there is no mobile export path; content remains in the user's own
   Cloudflare account and is exportable from any desktop install. Exports are
   read-side artifacts: editing an exported file does not write back to the CMS
   (the API is the write path; the app warns if it detects divergence).

**How the builder gets the site without git or GitHub:** the build container needs
code + content. Content comes from D1 through an **Astro content-layer loader** in
the template that reads the Worker's **bulk content read endpoint** — a decided V-3
API requirement (owner, 2026-07-17): paginated, draft-filtered server-side, with a
change cursor for incremental builds (Micropub `q=source` stays the per-post read;
the bulk endpoint is the build-time read). The existing zod schemas validate loader
output exactly as they validate `glob()` files today — un-provisioned sites keep the
`glob()` loader and today's behavior. Code comes from the **deployed-source
bundle**: every desktop deploy uploads the built site's `Source/` snapshot to R2 as
a one-way artifact. No two-way git mirror, no sync protocol — code changes only
ever arrive via desktop deploys, content changes only ever arrive via the API, so
the two lanes never conflict.

The phone therefore never touches git — **no local clone, no SwiftGit2, no push
credentials** — and neither does the builder.

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
   edit → Micropub update. Acceptance is canonical (§C.4); nothing else has to
   happen for the edit to be real.
4. **Publish:** flip the post to published (Micropub update of `post-status`) → the
   Worker triggers the bake (§C.4); the app shows "published — site rebuilding" for
   the seconds-to-minutes the bake takes, then the live URL. Webmention/POSSE for
   micropub-authored posts ride V-3's server-side machinery rather than the
   app-side desktop commands.

There is **no fake local preview** — rendering Markdown to HTML app-side would be a
second Markdown implementation diverging from Astro's, shown in site-unlike CSS. The
styled editor is the draft surface; the deployed site is the truth.

### C.6 Desktop flow

Two modes, split by provisioning state:

- **Un-provisioned sites (today's model, unchanged):** file-based typed editors,
  per-edit git commits, container build + deploy. Plus the new publish verbs: a
  post's editor and the navigator get **Publish/Unpublish** (menu + toolbar, proper
  Mac conventions per the mac-assed spec) flipping Part B's `draft` field. The
  dev-server preview keeps showing drafts (dev mode renders `draft: true` entries
  with a "Draft" badge — dev-only, filtered from builds).
- **Provisioned sites (CMS mode):** typed content editors keep their exact UI
  (`TypedEntryEditorView` + `MarkdownTextView`) but the model's save path writes
  through `MicropubClient` instead of `FileDocumentIO` + git — one write path for
  all clients, so Mac and phone edits can't diverge. Code/theme/pages stay
  file-based and git-committed exactly as today; a desktop deploy of code also
  uploads the deployed-source bundle (§C.4) so subsequent Worker-triggered bakes
  build against current code. Content edits alone don't need the desktop's
  container at all — the Worker bakes.
- **Offline desktop editing in CMS mode** uses the same queued-local-draft posture
  as mobile (§C.5), stated honestly in the UI rather than pretending file-grade
  offline; the files under `Source/src/content/` are exports, labeled as such.

### C.7 Provisioning (V-2.1, reused as-is)

Enabling publishing for a site *is* enabling the site's social features — the V-2.1
(#353) provisioning sequence run from the desktop app (existing `keychainTokenSource`
token → D1 database → R2 bucket → `wrangler.toml` bindings → `worker/worker.ts`
composition with `@dwk/micropub` + IndieAuth enabled → deploy), plus two steps this
spec adds: a one-time **content import** (existing `src/content/` entries migrate
into D1/R2 so the CMS starts complete, with the pre-import files preserved in git
history) and the first **deployed-source bundle** upload (§C.4). All of it is against
the user's own Cloudflare account; the conformance gate (`workers-version.json` +
`gateStatus(for:)`) decides when the app offers it. If the user later runs Publish to
GitHub (#68), that remains an optional code mirror; nothing in this path references a
git host.

## Data flow

```
        ┌── un-provisioned site (all-git — today's model, unchanged) ─────┐
 edit (MarkdownTextView) → save → commit (SwiftGit2)                      │
   → Publish: draft:false + commit ──► ContainerPublishPipeline           │
                                        build → scan ✗→ blocked UI        │
                                        └─► wrangler deploy → URL         │
        └─────────────────────────────────────────────────────────────────┘
        ┌── provisioned site (CMS mode — gated on V-3 workers) ───────────┐
 compose (MarkdownTextView + typed fields; Mac AND iOS, offline-queued)   │
   → Micropub create/update (post-status draft|published, media → R2)    │
       [IndieAuth token, user's own site]                                 │
       └─► per-site Worker: D1/R2 = CANONICAL content store               │
             ├─► continuous export → Source/src/content/ (portability;   │
             │     one-way, File ▸ Export always yields a complete site)  │
             └─► Worker-triggered bake (ephemeral build container):       │
                   code    ⇐ deployed-source bundle (R2, from desktop)    │
                   content ⇐ D1 via Astro content-layer loader            │
                   npm run build:ci                                       │
                     build → pre-deploy-check --strict ✗→ no deploy      │
                     └─► deploy → post live (seconds–minutes)             │
        └─────────────────────────────────────────────────────────────────┘
 code/theme changes (either mode): git commit → desktop container deploy,
 which also refreshes the deployed-source bundle for future Worker bakes
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
- **Bake lag / in flight** → an accepted publish shows "published — site rebuilding"
  with the bake's live status; the app never fakes a live URL before the deploy
  confirms. Rapid consecutive publishes coalesce into one rebuild.
- **Bake build failure** → distinguish gate-blocked (scan envelope → existing
  blocked-deploy UI with categories/remediation) from plain build errors (log excerpt
  + full log, streamed from the build container). A failed bake leaves the previous
  deploy live — static hosting's natural atomicity — and the canonical content is
  untouched in D1.
- **Stale deployed-source bundle** → a Worker bake against an old code bundle is
  correct-but-stale by design (content is current, code is last-deployed); the app
  surfaces "code changes not yet deployed" as existing dirty-state UI, never as a
  bake error.
- **Draft leakage backstop** → optional pre-deploy-check addition: fail if any
  `post-status: draft` record (or `draft: true` file entry in un-provisioned mode)
  has a corresponding page in `dist/` (cheap route check; belt-and-suspenders on top
  of the loader's server-side filtering).
- **Concurrent editing** (Mac and phone both in CMS mode) → one write path: both go
  through the API, resolved by ordinary compare-and-swap on the post record
  (`q=source` re-fetch on conflict). Editing an *exported file* does not write back;
  the app labels exports and warns on divergence rather than guessing intent.
- **Media constraints** → media-endpoint upload failures and R2 size limits surface
  per-attachment with retry; a post never partially publishes with missing media.
- **CMS unreachable at build time** → the loader fails the build loudly (no silent
  empty collections); the previous deploy stays live.

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
- **Export fidelity (cross-repo, V-3.4's suite + a fixture here):** a CMS post
  exports to Markdown + frontmatter that parses back through
  `FrontmatterDocument`/the registry schema losslessly, `post-status` maps to
  `draft` exactly, and import → export is the identity (so provisioning's one-time
  content import is provably lossless).
- **Content-layer loader (template suite):** loader output validates against the
  same zod schemas as `glob()` files; drafts filtered; CMS-unreachable fails the
  build; un-provisioned sites build identically to today.
- **`build:ci` producer test:** fresh scaffold, seeded PII blocker → `npm run build:ci`
  exits non-zero *after* building; clean scaffold exits zero (extends the #742
  producer→consumer fixture lane).
- **One opt-in live e2e** (gated like the container/e2e suites, real Cloudflare
  account, once V-3 packages exist): provision (including content import + bundle
  upload), post via Micropub, assert D1 accept → Worker-triggered bake → live URL,
  a draft never appears in `dist/`, and File ▸ Export yields a complete buildable
  site.

## Phasing

1. **Slice 1 — editor on macOS:** `AnglesiteMarkdown` + `MarkdownTextView` +
   `.markdown` routing; Format menu + Find (#517). No behavior change to saving.
2. **Slice 2 — draft/publish model:** template schema + filtering, registry `draft`,
   drafts-by-default, desktop Publish/Unpublish verbs over the existing container
   pipeline.
3. **Slice 3 — `build:ci` + bake groundwork:** the template `build:ci` script,
   envelope-from-log parsing, the content-layer loader seam (glob vs API selection),
   and the deployed-source bundle upload on desktop deploy — all exercised by the
   desktop pipeline now, so the contracts are proven before any Worker consumes them.
4. **Slice 4 — CMS mode** *(gated on V-3 `@dwk/workers` conformance — blocked until
   that milestone is green, like every V-3 feature)*: `MicropubClient` in
   AnglesiteCore (shared by the Mac editors' CMS-mode save path and iOS), IndieAuth
   onboarding, provisioning's content import, iOS compose UI (ported typed/markdown
   editors), post/draft/publish flows. The Worker-side pieces — content API,
   Worker-triggered bake orchestration, continuous export (V-3.4 #362 re-scoped to
   export) — are workers-repo deliverables slice 4 consumes.

Slices 1–3 have no dependency on the workers repo and can land now; slice 4 is the
gated feature.

Each slice is deterministic Swift/TypeScript end-to-end (no LLM path), per the #459
direction.

## Out of scope

- WYSIWYG rich-text editing that rewrites Markdown; the Component Editor (#496) owns
  visual editing of components.
- Media/photo posting *UX* from mobile — the transport is settled (Micropub media
  endpoint → R2, exported alongside content), but capture/compression/alt-text UX is
  its own design.
- **Git as the mobile transport** — an earlier revision designed a phone-side
  SwiftGit2 clone pushing to a bespoke R2-backed git origin. Superseded by the
  Micropub decision (§C.2): it duplicated the posting API the pivot already ships
  and put git plumbing on the phone for no user-visible gain.
- **Git-canonical content with a Cloudflare mirror ("option A")** — the alternative
  to CMS canonicality: keep #72/C.3 intact and maintain a two-way-synced
  Cloudflare-resident repo for the Worker-triggered builder. Considered and
  rejected (owner, 2026-07-17) in favor of Cloudflare-canonical content: A keeps
  two write paths (files and API) that must reconcile, while B has one write path
  per lane and a strictly simpler one-way export.
- MetaWeblog / AtomPub — rejected, rationale recorded in §C.2.
- Workers Builds for GitHub-mirrored repos — optional follow-on, never the default.
- Tables/LaTeX/wiki-link editor affordances; inline image thumbnails (fast-follow).
- Merging the template `blog` collection with typed `articles` (open question below).

## Open questions (owner input wanted)

Resolved during review (2026-07-17), recorded in §C.4: the bulk content read
endpoint is a V-3 API requirement; received interactions unify under the
D1-canonical + export model; export is desktop-only (no mobile export path).

1. **`blog` vs `articles`** — keep both (blog = simple starter, articles = typed
   h-entry) or migrate the starter to `articles` and retire `blog`? (In CMS mode the
   distinction also decides which collections the content import migrates.)
2. **iOS product shape** — is the Micropub client the *whole* default iOS experience
   (with the remote-sandbox thin client as the "power preview" opt-in), or do they
   ship together? This spec assumes the former.
3. **swift-markdown-engine adoption** — if the in-house styler's macOS feel lags the
   reference, is a scoped adoption of SwiftMarkdownEngine behind the `MarkdownTextView`
   seam (macOS only, new-dep approval) acceptable as a stopgap?
