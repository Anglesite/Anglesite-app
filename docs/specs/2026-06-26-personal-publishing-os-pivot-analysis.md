# Pivoting Anglesite to a "Personal Publishing Operating System"

**Date:** 2026-06-26
**Status:** Analysis / strategy review (no implementation)
**Input:** The "Anglesite Vision — A Personal Publishing Operating System" brief.
**Question answered:** What would actually have to change — in product scope,
architecture, and roadmap — to pivot the shipping app to this vision?

---

## 1. TL;DR

This is **less a pivot than a re-pointing of an already-aligned foundation, plus
one genuinely new product surface (the social/federation layer) that the app does
not have any of today.**

The vision's *principles* — ownership, local-first, static-by-default, open
standards, AI-as-assistant, beautiful defaults — are already the app's stated
invariants. The git-repo-as-source-of-truth rule (#72), the `.anglesite` package
model (#242), the Astro static pipeline, the optional Apple-Intelligence brain,
and the per-site container runtime (#69) are *exactly* the substrate this vision
needs. None of that gets torn down.

What's missing is large and falls into five buckets, in rough order of difficulty:

1. **Typed content objects** (Note/Photo/Event/Reply/…) — today there are only
   Page, Post, Image. Medium lift, mostly additive.
2. **The IndieWeb protocol layer** (Webmention send+receive, Micropub, IndieAuth,
   ActivityPub, microformats, feeds, POSSE) — the engine that makes "every website
   social." **The app has none of it today — but it does not have to be built from
   scratch:** the [`@dwk/workers`](https://github.com/davidwkeith/workers) monorepo
   (first-party — same author as Anglesite) already implements this entire layer as
   composable Cloudflare Workers. So this bucket is **integration + deployment +
   config**, not greenfield protocol engineering. This is still the heart of the
   pivot, but the risk profile changes from "build a federation stack" to "adopt and
   wire one." (Maturity caveat: §5.2.)
3. **A per-site dynamic backend** to *receive* (webmentions, ActivityPub inbox,
   form posts). The app is static-deploy-only today; federation cannot be static.
   **`@dwk/workers` is exactly this backend** — a scale-to-zero Cloudflare Worker
   (self-hostable via `@dwk/server`), so the "make-or-break design spike" this
   document originally called for is largely *answered* by an existing component.
4. **Migration importers** (Facebook/Instagram/Mastodon/Bluesky/WordPress/Medium).
   Net-new; today's only "import" is Anglesite-dir → package.
5. **Communities** — first-class groups with membership, discussion, moderation.
   This is a second product, not a feature, and the hardest fit with static-first.

The honest framing: **principles ✅, foundation ✅, protocol layer ✅ (exists as
`@dwk/workers`, unreleased), integration + social-product ❌.** The pivot is
achievable *because* the architecture was built for it and the federation stack
already exists as a first-party package; the remaining work is wiring that backend
into the app's deploy/identity/content flows, the typed-object UX, importers, and
(separately) communities. The deferred *decisions* in §6 still need answering, but
several are now resolved by `@dwk/workers`' design.

---

## 2. What the app is today (grounded inventory)

So the gap analysis is concrete, here is what actually ships (verified against
the source, not the docs):

- **Shape:** native macOS app (macOS 27+, Apple Silicon only), four SPM targets
  (`AnglesiteApp` UI, `AnglesiteCore` engine ~180 files, `AnglesiteBridge`
  WKWebView, `AnglesiteIntents` Siri) + `AnglesiteContainer`.
- **Site = `.anglesite` package** (`AnglesitePackage.swift`): `Info.plist` (stable
  UUID), `Source/` (an Astro git repo — the canonical, clonable unit), `Config/`
  (app-owned, never in git). Discovered via a recents registry (`SiteStore`), not
  folder scans.
- **Content model:** `Page` (`src/pages/*.astro`), `Post` (markdown content
  collection), `Image` (`public/`), `Annotation` (sticky notes). Surfaced as a
  `SiteContentGraph` + lexical `SiteKnowledgeIndex`. **That's the entire object
  vocabulary** — three types, all generic.
- **Editing:** click-to-edit overlay in WKWebView → `apply_edit` MCP tool →
  selector patch + per-edit git commit. Plus Siri NL edit and an optional chat
  panel.
- **AI:** `ClaudeAgent` (DevID, being retired per the Claude-Code-removal roadmap)
  or on-device `FoundationModelAssistant` (both targets). Optional, tool-calling,
  no external LLM APIs by policy.
- **Runtime:** `SiteRuntime` protocol with `LocalSiteRuntime` (host subprocess) and
  `LocalContainerSiteRuntime` (Apple Containerization VM). HTTP/stdio MCP transport.
- **Deploy:** `DeployCommand` → `npm build` → `pre-deploy-check.ts` security gate →
  `wrangler deploy` to **Cloudflare only**. GitHub publish flow is half-built and
  in draft.
- **Social / IndieWeb / feeds / syndication / import-from-silos / communities:**
  **none.** Confirmed absent in code. The only "social" surfaces are third-party
  *embeds* (Giscus comments, booking, donations) — adding someone else's silo to
  your page, the opposite of owning the interaction.

---

## 3. The foundation that already aligns (keep, don't rebuild)

| Vision principle | Already satisfied by | Note |
|---|---|---|
| **Ownership first** — canonical copy on the user's site | `Source/` git repo is the source of truth (#72); app's working copy is non-canonical | This is *the* hardest cultural invariant to retrofit, and it's already load-bearing. |
| **Local first** — create offline | Local package, local git, local runtime | "Publish when connectivity returns" is a queue away (§5.3). |
| **Static by default** | Astro → `dist/` static output | Exactly the vision's stance. |
| **Open by default** | Astro/markdown/HTML, no proprietary store | The content *substrate* is open; the *protocols* are missing (that's §5.2). |
| **AI as assistant, never required** | FM chat is optional; Siri+GUI are primary | Already a "locked decision" in the Claude-removal roadmap. |
| **Beautiful by default** | `ThemeCatalog`/`ThemeApplier`, Astro themes | Partial — theme system is thin; vision's "rival the best platforms" bar is higher. |
| **Provider-agnostic hosting** | `SiteRuntime` protocol; deploy is a command, not a hard dependency | But deploy is *implemented* Cloudflare-only (§5.5). |
| **Per-site dynamic backend** *(needed for social)* | Cloudflare Workers + the container runtime investment | The single biggest architectural gift: the substrate for receiving webmentions / inbox already exists in-house. |

**Implication:** the "one capability → one implementation → three front-doors"
pattern (GUI / Siri / chat) from the Claude-removal roadmap extends cleanly to
social actions ("reply", "like", "follow", "syndicate"). The pivot rides existing
rails rather than laying new ones for the *interaction* model.

---

## 4. Re-prioritization, not contradiction

The current roadmap (Phase 10: MAS shipping, containerization, Siri, Claude-Code
removal) is **orthogonal** to the vision, not opposed to it — but it is optimized
for a *different product*: "an AI-assisted business-website builder for
non-technical owners." The vision is "own your social web." Almost everything
in-flight (package model, container runtime, deterministic Swift, Apple
Intelligence) is reusable. What changes is **what gets built next and why**:

- The Claude-Code-removal work continues (it's about substrate, not scope).
- The "integrations wizard" framework already lists `indieweb` as a to-port item
  (Bucket 3 of that roadmap) — but as a single vague placeholder. The pivot
  **promotes IndieWeb from one wizard to the spine of the product**, implemented by
  composing the first-party `@dwk/workers` stack (§5.2) rather than building
  protocols in-house.
- "Communities" is not on any current roadmap and would be a new epic on the scale
  of the whole containerization effort.

---

## 5. The gaps — what must be built

### 5.1 Typed content objects (medium lift, additive)

Vision wants ~20 first-class types (Note, Article, Photo, Album, Event, Bookmark,
Like, Reply, Repost, RSVP, Review, Recipe, Trip, Reading, Listening, …), each with
a purpose-built editor. Today: 3 generic types.

**What it takes:**
- A content-type registry in `AnglesiteCore` (extend `SiteContentGraph` /
  `ContentScaffold`) where each type declares its frontmatter schema, its
  microformats2 mapping (`h-entry` + `u-*`/`p-*`/`dt-*` properties), its editor
  UI, and its template. This maps almost 1:1 onto **IndieWeb post types** — adopt
  that vocabulary rather than inventing one.
- Per-type SwiftUI editors (the vision's "feel like Notes/Photos" UX). The
  existing overlay/`FileEditorModel` handle freeform editing; typed objects need
  structured forms (a photo picker, a date+location picker for Events, a
  URL-of-the-thing-you're-replying-to field for Replies).
- Each type also needs an Astro template + content-collection schema in
  `Resources/Template/`, and App-Intent entities (the `ContentEntities` pattern
  already exists for Page/Post/Image — extend it).

This is the most tractable pillar: it's additive, fits existing patterns, and is a
prerequisite for everything social (a "Reply" *is* a content object with a
`u-in-reply-to`).

### 5.2 The IndieWeb protocol layer — adopt `@dwk/workers`

"Every website is social" = the site implements the IndieWeb building blocks. The
app has none of them today, but **they are not greenfield work**: the first-party
[`@dwk/workers`](https://github.com/davidwkeith/workers) monorepo already
implements the full stack as composable Cloudflare Workers (handlers compose into
one Worker via path routing; bindings in `wrangler.toml`; D1 / R2 / KV / Durable
Objects for state). Each protocol the vision needs maps to an existing package:

| Capability the vision needs | `@dwk/workers` package | Static / dynamic |
|---|---|---|
| External posting clients (phone/3rd-party → site) | `@dwk/micropub` (create/update/delete; media → R2) | Dynamic |
| Inbound mentions (comments/likes on your page) | `@dwk/webmention` (receive + send; async verify queue; inbox store) | Dynamic |
| Sign-in / auth for the above | `@dwk/indieauth` (authz, tokens, metadata, PKCE) | Dynamic |
| Federation (Fediverse interop, followers) | `@dwk/activitypub` (per-actor inbox/outbox, HTTP Signatures, S2S delivery) | Dynamic |
| "Follow" / read others | `@dwk/microsub` (subscriptions, Atom/RSS/JSON polling, normalized timeline) | Dynamic |
| Notify subscribers on publish | `@dwk/websub` (W3C hub, D1 store, HMAC distribution) | Dynamic |
| Discovery / identity rooted at your domain | `@dwk/webfinger`, `@dwk/host-meta`, `@dwk/vc` (did:web), `@dwk/webauthn` (passkeys) | Dynamic |
| Marked-up content (microformats2 h-entry/h-card) | *App/template work* — emit mf2 from Astro templates | Static (build-time) |
| Feeds (RSS / Atom / JSON Feed) | *App/template work* — generate at build (also consumed by `microsub`/`websub`) | Static (build-time) |

So the only *protocol* pieces the app team writes are the **static, build-time**
ones (mf2 markup + feed generation in `Resources/Template/`). Everything dynamic is
**integration**: provision a per-site Worker that composes the needed `@dwk/*`
handlers, wire its bindings, deploy it, and surface its received interactions on
the site (build-time pull and/or client-side fetch).

**This resolves the document's original central question — "static hosting cannot
receive, so what's the backend?"** The backend is `@dwk/workers`. Its stated design
("the data and keys live only on infrastructure the user owns — serverless edge on
Cloudflare, or a single self-hosted process") matches the vision's ownership stance
exactly. Note: **per the v1 scope decision, the only deploy/runtime target is
Cloudflare Workers** (§5.5); `@dwk/server` self-hosting (Docker/Node + SQLite)
exists in the package but is **out of scope for v1**.

**Integration work the app actually owns for this pillar:**
- A "provision social backend" flow: create the D1/R2/KV bindings + deploy the
  composed Worker for a site, reusing the existing Cloudflare token machinery
  (`KeychainStore`, `CloudflareTokenVerifier`, `wrangler`).
- Map typed content objects (§5.1) onto Micropub create/update/delete so editing in
  the app and posting via Micropub are the *same* operation on the canonical repo.
- Render received webmentions/replies/likes (from the Worker's inbox store) onto the
  static site — snapshotting them into git so they survive backend loss (§6.2).
- App-side UI for the reader/timeline (`microsub`) and follower management
  (`activitypub`).

**Maturity caveat (real risk):** `@dwk/workers` is version `0.0.0`, unreleased, with
spec conformance (micropub.rocks / webmention.rocks / Solid) tracked but *pending*.
Anglesite's social-layer readiness is therefore **gated on that package reaching a
stable, conformant release**. It's first-party (same author), which lowers
coordination risk and makes paired releases natural — but the dependency must be
planned as a co-evolving component, not an off-the-shelf given. Pin versions; track
its conformance milestones as explicit prerequisites for the V-2/V-3 phases (§7).

POSSE (Publish Own Site, Syndicate Elsewhere) sits on top: on publish, cross-post
to Mastodon/Bluesky/etc. and record the syndication URLs back onto the canonical
post (backfeed via Webmention, handled by `@dwk/webmention`). Note the current
Claude-removal roadmap's `syndicate` is *generative copy variants* (Bucket 5) —
**that is not POSSE**; real syndication is API posting + backfeed plumbing, a
deterministic capability layered over `@dwk/workers`, not an AI one.

### 5.3 Invisible publishing + local-first queue

Vision: "there should rarely be a visible Publish button"; edits auto-regenerate,
update feeds, send webmentions, syndicate, deploy. Today publishing is an explicit
`DeployModel` button → full build → Cloudflare.

**What it takes:**
- A **publish pipeline / queue** that debounces edits, rebuilds incrementally,
  and on reconnect performs: deploy → feed regen → webmention send → POSSE →
  subscriber notify. Offline edits queue locally (git already gives durable local
  state); the queue drains when connectivity returns.
- This is a state-machine generalization of today's `DeployCommand`, plus
  background scheduling. The `pre-deploy-check` security gate stays in the path
  (it's an invariant) — which means "invisible" publishing still can't bypass it;
  surface blocks as notifications rather than a modal.

### 5.4 Migration / import (net-new)

Importers for Facebook, Instagram, Mastodon, Bluesky, WordPress, Blogger, Medium,
RSS, Markdown. Today `PackageTransfer` only does Anglesite-dir ↔ package.

**What it takes:** per-source archive parsers that map silo exports → typed content
objects (§5.1) + media into `public/` + git history. This is well-bounded,
parallelizable work (one parser per source), ideal for the Node sidecar (the JS
ecosystem has libraries for most of these formats). The parse/scrape is
deterministic (Bucket 3); only optional cleanup/reformatting is AI (Bucket 5).
A good *first* importer to prove the pipeline: Mastodon or RSS (clean,
well-specified) before Facebook (messy, huge archives).

### 5.5 Deploy target: Cloudflare Workers only (v1 — decided)

The vision lists Cloudflare, GitHub Pages, Netlify, generic static, and
self-hosted. **For v1 this is deliberately narrowed to Cloudflare Workers only;
the other targets are dropped for now.** This is the right call and removes work
rather than adding it:

- Deploy stays on the existing `wrangler` path in `DeployCommand` — **no
  `DeployTarget` abstraction or per-provider adapters needed for v1.** (The
  half-built GitHub publish flow, `GitHubAuthFlow`/`PublishModel`, is not a deploy
  target; GitHub stays only as the `Source/` repo host.)
- It makes the static site and the dynamic social backend share one substrate:
  both the static assets *and* the `@dwk/workers` social Worker deploy to
  Cloudflare with the same account/token. There is no "static host can't receive"
  split to design around (the original §5.2 caveat) and no reduced "publish-only"
  tier to explain — **every published site can receive**, because every site is on
  Workers.
- Multi-target deploy becomes a post-v1 concern. When it returns, it reintroduces
  exactly the tension this narrowing avoids (pure-static targets can host the site
  but not the inbox), so it should come back as an explicit, well-scoped feature —
  not be half-supported now.

The only honest trade-off to record: **v1 hard-couples a published Anglesite site
to Cloudflare.** That sits in mild tension with the vision's "hosting providers
become interchangeable implementation details" and "self-hosted" goals (§6.3) — but
as a *v1 scope decision* it is sound; interchangeability is a later promise, not a
v1 one.

### 5.6 Communities (a second product)

First-class groups (neighborhood, club, family, …) with announcements, threaded
discussion, events/calendars, member directories, galleries, and **moderation**.

This is the **least aligned** pillar and the biggest single risk:

- Discussion + membership + moderation are inherently **multi-user, multi-writer,
  always-on** — the antithesis of "static, single-author, local-first." A
  community is not one person's git repo.
- It needs identity/auth across members, real-time-ish state, spam/abuse handling,
  and a hosting model where no one member's laptop is the server.
- The honest options: (a) build it as a federated app on ActivityPub *Groups*
  (ride the `@dwk/activitypub` layer from §5.2 — most on-vision, hardest); (b) a
  shared per-community Worker + D1 backend the app provisions (pragmatic, and a
  natural extension of the same `@dwk/workers`-on-Cloudflare substrate the personal
  sites use); (c) defer it entirely to a later version.
- **Recommendation:** treat communities as a *separate epic gated behind the
  personal IndieWeb layer landing first*. Do not let it block or define the
  personal-publishing pivot. It reuses the §5.2 backend (composed `@dwk/workers` on
  Cloudflare) but is a distinct product with its own design spike.

### 5.7 Discovery (net-new, and in tension with "no centralization")

"Discover nearby communities / shared interests / local events / independent
creators without centralized recommendation algorithms." This needs *some*
index — you cannot discover a network of static sites without a directory or
crawl. Likely an **opt-in directory / aggregator service** (which is a
centralized-ish component, however federated or open its data). Smallest viable
version: consume existing open networks (Fediverse discovery, IndieWeb webrings,
feeds you follow) before building anything new. Flag honestly: full discovery
contradicts "no centralized service" unless reframed as "opt-in, open-data,
self-hostable directory."

### 5.8 Platform strategy — one Apple app (macOS + iOS + iPadOS); Windows/Linux separate (decided)

**Decision:**
- **This codebase is the Apple app: macOS, iOS, and iPadOS share it** — one
  Apple-native SwiftUI codebase, with a **different feature set per device** (the
  Mac is the full editor; iPhone/iPad are leaner, capture-and-publish-oriented).
- **Windows and Linux are *separate* native apps**, rebuilt for those platforms —
  not a port of this one, sharing concepts and *standards* but not code.

This dissolves the cross-platform/AI contradiction an earlier draft flagged:

- The Apple app keeps its Apple-native stack (SwiftUI, FoundationModels, App
  Intents) and the "Apple Intelligence only, no external LLM APIs" decision
  **without compromise across all three Apple platforms** — FoundationModels and App
  Intents exist on iOS/iPadOS too, so the invariant holds device-to-device.
- iOS/iPadOS use the **remote Cloudflare runtime** (`RemoteSandboxSiteRuntime`,
  #66/#71) because phones can't run local containers — already the planned design;
  it dovetails with the Cloudflare-only v1 decision (§5.5). The Mac keeps its local
  container runtime. Same app, runtime chosen per device.
- The future **Windows/Linux** apps pick whatever AI substrate fits their OS,
  independently — no single decision spans Apple and non-Apple worlds.
- **What makes the non-Apple "separate apps" coherent rather than fragmenting is the
  open substrate**: every app — Apple or not — operates on the same two shared
  truths, the site's `Source/` **git repo** (canonical content) and the
  **`@dwk/workers` backend** (the social/identity layer over Micropub, IndieAuth,
  ActivityPub, Webmention). A separate Windows app is "just another IndieWeb client"
  against those, exactly as the vision intends ("interoperate instead of replace") —
  the apps are interchangeable clients; the user's site is the durable identity.

So platform breadth is no longer a contradiction to "resolve before building." The
Apple app spans macOS/iOS/iPadOS by feature set (iOS/iPad as a leaner V-4-era
addition over the same code); the vision's "future: Windows, Linux" becomes
downstream **native** apps, neither gating the Apple pivot.

---

## 6. The hard tensions the vision must resolve (decide before building)

These are the places the vision is internally under-specified. They are decisions,
not tasks, and they gate the roadmap:

1. **"No cloud account required" vs. being social.** You can *author* with no
   account, but *receiving* followers/webmentions and *deploying* require an
   always-on host and therefore *some* account somewhere. Reconcile as: "no
   account to **create**; one hosting connection to **publish/receive**." Say it
   plainly in the product.

2. **Static-first vs. the inbox.** *Largely resolved* — the receiving backend is
   `@dwk/workers` (§5.2), and the v1 Cloudflare-only decision (§5.5) means static
   assets and the social Worker share one host, so there's no static-vs-dynamic
   hosting split to design around. What remains is a *data-canonicality* decision,
   not a hosting one: the canonical site is now static `dist/` **+** a dynamic
   backend, so #72 ("git is the source of truth") must say what is canonical about
   received interactions (a webmention you received is someone else's content,
   cached in the Worker's inbox store — is it in your git repo? IndieWeb practice:
   yes, snapshot it back into `Source/` so it survives backend loss).

3. **"No centralized" vs. discovery, communities — and v1's Cloudflare coupling.**
   Discovery and communities need shared infrastructure; reframe to "opt-in, open,
   self-hostable" or accept a thin directory. Separately, **v1 is Cloudflare-only
   (§5.5)**, which couples a published site to one provider — acceptable as a v1
   scope decision but in tension with the vision's "interchangeable hosting" and
   "self-hosted" goals. `@dwk/workers` keeps the *door* open (it ships a
   self-hostable `@dwk/server`), so the coupling is a v1 choice, not a permanent
   architectural lock-in. Say plainly: v1 = Cloudflare; interchangeability/self-host
   = later.

4. **Apple-only AI vs. cross-platform reach — resolved by decision (§5.8).** One
   Apple app spans **macOS + iOS + iPadOS** (shared code, per-device feature set);
   **Windows/Linux** are **separate native apps**, not ports. The
   Apple-Intelligence-only invariant therefore holds without compromise across all
   Apple devices, and the non-Apple apps converge through the shared open substrate
   (the site's git repo + the `@dwk/workers` backend) rather than shared code. No
   longer an open tension — the residual work is keeping those interface contracts
   clean and documented so the future native apps can target them.

5. **"No templates / no publish button / understands intent" vs. power-user
   git ownership.** The vision's UX (Notes-like, invisible) and the #72 invariant
   (it's a real git repo anyone can clone) are compatible but in constant tension —
   every "magic" automation must leave clean, human-legible git history and files,
   or the ownership promise is hollow. The existing per-edit-commit discipline is
   the right precedent; extend it.

6. **Scope explosion / focus.** The vision lists ~10 products to replace now and
   ~8 more later. Attempting all is fatal. The leverage point is the **personal
   IndieWeb site** (notes, photos, articles, replies, feeds, webmention, POSSE) —
   that single slice replaces blogs, Linktree, basic social posting, and digital
   gardens, and *everything else builds on it*. Communities, commerce, and
   newsletters are later layers, not v1.

---

## 7. Suggested phasing

Each phase is independently shippable and ordered so the social layer rests on
solid content/protocol foundations.

Scope guards baked into the phases below: **one Apple app (macOS + iOS + iPadOS)**
with Windows/Linux as separate native apps (§5.8), **Cloudflare-only deploy** (§5.5),
and the social layer is **composed from `@dwk/workers`**, not built in-house (§5.2). The
`@dwk/workers` integration phases are gated on that package reaching a stable,
conformant release.

| Phase | Theme | Contents | Vision products unlocked |
|---|---|---|---|
| **V-0** | *Finish the substrate* | Continue Claude-removal + MAS + container runtime (already in flight). No vision-specific work; just don't stall it. | — |
| **V-1** | *Typed content + feeds* | Content-type registry (§5.1) for Note/Article/Photo/Album/Bookmark; per-type editors; **RSS/Atom/JSON feeds** + **microformats2** in templates (the only protocol pieces written in-app — both static). | Blog, digital garden, link collection, photo album, portfolio. |
| **V-2** | *Make it social (outbound)* | Provision the per-site **Cloudflare Worker** composing `@dwk/webmention` (send) + `@dwk/indieauth`; POSSE syndication to Mastodon/Bluesky (API posting + backfeed via `@dwk/webmention`); the publish queue / "invisible publish" (§5.3). | "Publish once, syndicate everywhere"; replaces basic social posting. |
| **V-3** | *Make it social (inbound)* | Add `@dwk/micropub` + `@dwk/webmention` (receive) + `@dwk/websub` to the Worker; received interactions rendered on the page + snapshotted to git; typed objects wired to Micropub create/update/delete. | Comments/likes/replies on your own site; posting from external/IndieWeb clients. |
| **V-4** | *Migration + reach* | Importers (§5.4, start Mastodon/RSS → WordPress → Facebook/Instagram). | "Leaving platforms is painless." |
| **V-5** | *Federation + reader* | Add `@dwk/activitypub` (actor/inbox/outbox/followers) + `@dwk/microsub` (follow/timeline) + `@dwk/webfinger`/identity. | Appear natively in the Fediverse; follow others; replaces Mastodon-class following. |
| **V-6** | *Communities + discovery* | Separate epic (§5.6/§5.7), gated on V-3/V-5 backend. Spike first. | Groups, Meetup, neighborhood/club sites. |

**iOS/iPadOS** ride this same Apple codebase with a leaner feature set (natural
around V-4, on the remote Cloudflare runtime — §5.8), not a separate effort. Out of
v1 scope by decision (revisit later, none on the critical path): multi-provider
deploy (§5.5), self-hosting via `@dwk/server`, and the separate native
**Windows/Linux** apps (§5.8). Commerce, newsletters, and membership layer onto
V-1/V-3 via the existing integration-wizard framework.

---

## 8. Recommended near-term decisions

Three scope decisions are now locked and remove the biggest open questions an
earlier draft raised: **one Apple app — macOS + iOS + iPadOS** (Windows/Linux as
separate native apps, §5.8), **Cloudflare-only deploy for v1** (§5.5), and **the
protocol layer is `@dwk/workers`, not in-house** (§5.2). With those settled, the first concrete moves
are:

1. **Adopt IndieWeb as the explicit content + protocol model** (not a single
   wizard). Rewrite the content-graph and template story around h-entry post types,
   and treat `@dwk/workers` as the protocol backend. This is the keystone decision;
   most of §5 follows from it.
2. **Drive `@dwk/workers` to a stable, conformant release and stand up the
   integration seam** (§5.2). The make-or-break dependency is no longer "can we
   design a per-site backend" (it exists) but "is `@dwk/workers` released and
   passing micropub.rocks / webmention.rocks." Pin it, track its conformance as a
   prerequisite for V-2/V-3, and build the app-side "provision + deploy a per-site
   Worker" flow over the existing Cloudflare token machinery.
3. **Settle the residual data-canonicality question** (§6.2): how received
   interactions snapshot from the Worker's inbox store back into `Source/` git so
   #72 still holds. This is the one genuinely new architectural decision left.
4. **Ship feeds + microformats + one importer + Webmention-send first** (V-1 →
   start of V-2). The cheapest path to a credible "owns your social web" story; the
   in-app pieces are static/deterministic and the dynamic pieces are `@dwk/*` config.
5. **Quarantine Communities** behind its own design effort. It's the tail that
   could wag the dog; don't let it reshape the personal-publishing core.

**Bottom line:** the architecture team has, perhaps inadvertently, built almost the
perfect foundation for this vision — ownership, git-canonical, static-first,
optional-AI, per-site Cloudflare runtime — and the hardest missing piece, the
federation/social protocol stack, **already exists as the first-party
`@dwk/workers`**. The pivot is real and large, but it is mostly *additive and
integrative* (wire in `@dwk/workers` + typed objects + importers) rather than a
teardown or a from-scratch protocol build. With the Apple-app scope (macOS/iOS/
iPadOS), Cloudflare-only deploy, and `@dwk/workers` as settled constraints, the
residual hard problems shrink to two:
**data canonicality of received interactions** (§6.2, a decision) and
**communities** (§5.6, a separate product). Sequence around those and the rest is
disciplined, incremental delivery on rails that already exist.
