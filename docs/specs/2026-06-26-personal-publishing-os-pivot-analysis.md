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
2. **The IndieWeb protocol layer** (RSS/Atom, Webmention send+receive, Micropub,
   h-entry microformats, POSSE syndication) — the engine that makes "every website
   social." **None of it exists.** This is the heart of the pivot.
3. **A per-site dynamic backend** to *receive* (webmentions, ActivityPub inbox,
   form posts). The app is static-deploy-only today; federation cannot be static.
4. **Migration importers** (Facebook/Instagram/Mastodon/Bluesky/WordPress/Medium).
   Net-new; today's only "import" is Anglesite-dir → package.
5. **Communities** — first-class groups with membership, discussion, moderation.
   This is a second product, not a feature, and the hardest fit with static-first.

The honest framing: **principles ✅, foundation ✅, social/community product ❌.**
The pivot is achievable *because* the architecture was built for it, but the
social layer is 60–70% of the remaining work and forces decisions the current
roadmap has deferred (see §6, the tensions).

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
  **promotes IndieWeb from one wizard to the spine of the product.**
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

### 5.2 The IndieWeb protocol layer (the heart of the pivot)

"Every website is social" = the site implements the IndieWeb building blocks.
Nothing here exists today.

| Capability | Standard | Static or dynamic | Notes |
|---|---|---|---|
| Feeds | **RSS / Atom / JSON Feed** | Static (build-time) | Pure build step; even the existing blog spec defers this. Easiest. |
| Marked-up content | **microformats2 (h-entry/h-card)** | Static (build-time) | Theme/template work; prerequisite for Webmention + reader compat. |
| Outbound mentions | **Webmention (send)** | Build/deploy step | On publish, parse links, POST to targets' endpoints. |
| Inbound mentions | **Webmention (receive)** | **Dynamic** | Needs an always-on endpoint + storage; comments/likes appear on your page. |
| External posting clients | **Micropub (server)** | **Dynamic** | Lets the phone/3rd-party apps post to the site. |
| Sign-in | **IndieAuth** | **Dynamic** | Identity for Micropub/Webmention auth. |
| Federation | **ActivityPub** (inbox/outbox, actor, followers) | **Dynamic** | Mastodon/Fediverse interop. The heaviest protocol; a per-site actor + signed delivery. |
| Read others | **Microsub / feed reader** | Dynamic or client | "Follow" in the vision; could be client-side in the app initially. |

**The architectural fork this forces:** static hosting *cannot receive*. Webmention
receipt, Micropub, IndieAuth, and ActivityPub inbox all require an always-on
endpoint with storage. The vision explicitly allows this ("dynamic capabilities
layered on using APIs and edge functions only when needed"), and **the app already
owns the right substrate** — Cloudflare Workers + D1/R2, plus the container
runtime. The pivot's central engineering decision is: **ship a small per-site
"social backend" Worker** (inbox, webmention receiver, micropub endpoint, feed of
received interactions) that the static site reads from at build time and/or via
client-side fetch. This is a new deploy artifact alongside the static `dist/`.

POSSE (Publish Own Site, Syndicate Elsewhere) sits on top: on publish, cross-post
to Mastodon/Bluesky/etc. via their APIs and record the syndication URLs back onto
the canonical post (backfeed via Webmention/Bridgy). Note the current
Claude-removal roadmap's `syndicate` is *generative copy variants* (Bucket 5) —
**that is not POSSE**; real syndication is API posting + backfeed plumbing, a
deterministic Bucket-3-style capability, not an AI one.

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

### 5.5 Multi-target deploy (medium lift)

Vision lists Cloudflare, GitHub Pages, Netlify, generic static, self-hosted.
`SiteRuntime` abstracts *running*; deploy is hardcoded to `wrangler`. Generalize
`DeployCommand` behind a `DeployTarget` protocol with per-provider adapters. The
half-built GitHub publish flow (`GitHubAuthFlow`, `PublishModel`) is the natural
second target. **Caveat:** the social backend (§5.2) needs a dynamic host —
GitHub Pages / pure-static targets can host the *site* but not the *inbox*, so
"self-hosted/static" users get a reduced (publish-only, no-receive) social tier
unless they also run the Worker elsewhere. This needs to be an explicit product
tier, not a silent gap.

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
  (ride the §5.2 layer — most on-vision, hardest); (b) a shared per-community
  Worker+D1 backend the app provisions (pragmatic, but "centralized hosting" the
  vision wants to avoid — though self-hostable); (c) defer it entirely to a v3.
- **Recommendation:** treat communities as a *separate epic gated behind the
  personal IndieWeb layer landing first*. Do not let it block or define the
  personal-publishing pivot. It reuses the §5.2 backend but is a distinct product
  with its own design spike.

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

### 5.8 Platform expansion

- **iOS / iPad** is already on the roadmap via `RemoteSandboxSiteRuntime` (#66/#71)
  — iOS can't run local containers, so it uses the Cloudflare remote runtime. The
  vision's "create like a note on your phone" depends on this; it's the natural
  next platform and partially planned.
- **Windows / Linux** ("future") **directly conflicts with a locked decision**:
  the AI substrate is *Apple Intelligence only, no external LLM APIs ever*, and
  the whole app is SwiftUI + Apple frameworks (Containerization, FoundationModels,
  App Intents). A Windows/Linux client cannot reuse any of it. This isn't a port;
  it's a second codebase with a different AI story. Either the "no external LLM"
  decision relaxes for non-Apple platforms, or Windows/Linux stays aspirational.
  **This contradiction must be resolved explicitly before promising cross-platform.**

---

## 6. The hard tensions the vision must resolve (decide before building)

These are the places the vision is internally under-specified. They are decisions,
not tasks, and they gate the roadmap:

1. **"No cloud account required" vs. being social.** You can *author* with no
   account, but *receiving* followers/webmentions and *deploying* require an
   always-on host and therefore *some* account somewhere. Reconcile as: "no
   account to **create**; one hosting connection to **publish/receive**." Say it
   plainly in the product.

2. **Static-first vs. the inbox.** Resolved by the per-site Worker (§5.2), but it
   means the canonical "site" is now static `dist/` **+** a dynamic backend. The
   `.anglesite` package and #72 ("git is the source of truth") must be extended to
   say what is and isn't canonical about received interactions (a webmention you
   received is someone else's content, cached on your backend — is it in your git
   repo? IndieWeb practice: yes, snapshot it, so it survives backend loss).

3. **"No centralized" vs. discovery & communities.** Both need shared
   infrastructure. Reframe to "opt-in, open, self-hostable" or accept a thin
   centralized directory. Don't claim zero centralization while shipping discovery.

4. **Apple-only AI vs. cross-platform reach.** §5.8. The mission ("everyone should
   have a home") sits uneasily with macOS-27 + Apple-Silicon-only. iOS broadens
   it; Windows/Linux breaks the AI invariant.

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

| Phase | Theme | Contents | Vision products unlocked |
|---|---|---|---|
| **V-0** | *Finish the substrate* | Continue Claude-removal + MAS + container runtime (already in flight). No vision-specific work; just don't stall it. | — |
| **V-1** | *Typed content + feeds* | Content-type registry (§5.1) for Note/Article/Photo/Album/Bookmark; per-type editors; **RSS/Atom/JSON feeds**; microformats2 in themes. | Blog, digital garden, link collection, photo album, portfolio. |
| **V-2** | *Make it social (outbound)* | Webmention **send**; POSSE syndication to Mastodon/Bluesky (real API posting + backfeed); the publish queue / "invisible publish" (§5.3). | "Publish once, syndicate everywhere"; replaces basic social posting. |
| **V-3** | *Make it social (inbound)* | The per-site **social backend Worker** (§5.2): Webmention **receive**, Micropub, IndieAuth; received interactions rendered on the page + snapshotted to git. | Comments/likes/replies on your own site; phone-app posting. |
| **V-4** | *Migration + reach* | Importers (§5.4, start Mastodon/RSS → WordPress → Facebook/Instagram); multi-target deploy (§5.5); iOS thin client (#71). | "Leaving platforms is painless"; phone authoring. |
| **V-5** | *Federation* | ActivityPub actor/inbox/outbox/followers; appear natively in the Fediverse. | Replaces following/followers on Mastodon-class networks. |
| **V-6** | *Communities + discovery* | Separate epic (§5.6/§5.7), gated on V-3/V-5 backend. Spike first. | Groups, Meetup, neighborhood/club sites. |

Commerce, newsletters, membership, and the heavier "replace Substack/Squarespace"
ambitions layer onto V-1/V-3 using the existing integration-wizard framework and
are deliberately *not* on the critical path.

---

## 8. Recommended near-term decisions

If the team wants to commit to this direction, the first concrete moves are:

1. **Adopt IndieWeb as the explicit content + protocol model** (not a single
   wizard). Rewrite the content-graph and template story around h-entry post types.
   This is the keystone decision; most of §5 follows from it.
2. **Design-spike the per-site social backend Worker** (§5.2). This is the
   make-or-break architecture; the rest of the social vision depends on whether the
   Cloudflare-Worker-per-site model is clean, cheap, and self-hostable. Prove it
   before promising federation.
3. **Resolve the six tensions in §6 in writing** — especially "no account / no
   centralization / cross-platform" — so the marketing vision and the engineering
   reality match. Several vision claims need softening to be truthful.
4. **Ship feeds + one importer + Webmention-send first** (V-1/start of V-2). It's
   the cheapest path to a credible "owns your social web" story, validates the
   typed-object work, and is almost entirely static/deterministic.
5. **Quarantine Communities** behind its own design effort. It's the tail that
   could wag the dog; don't let it reshape the personal-publishing core.

**Bottom line:** the architecture team has, perhaps inadvertently, built almost the
perfect foundation for this vision — ownership, git-canonical, static-first,
optional-AI, per-site dynamic runtime. The pivot is real and large, but it is
mostly *additive* (a protocol layer + typed objects + importers) rather than a
teardown. The two things that genuinely strain the current design are **receiving**
(static can't receive — answered by the per-site Worker) and **communities**
(multi-user — a separate product). Sequence around those two and the rest is a
matter of disciplined, incremental delivery on rails that already exist.
