# Implementation Plan — Personal Publishing OS Pivot

**Date:** 2026-06-26
**Status:** Plan (drives the GitHub epic + sub-issues)
**Design source:** [`docs/specs/2026-06-26-personal-publishing-os-pivot-analysis.md`](../../specs/2026-06-26-personal-publishing-os-pivot-analysis.md)

This plan turns the pivot analysis into buildable phases and tasks. It is the basis
for the GitHub tracking epic and its per-phase / per-task sub-issues.

## Settled constraints (from the analysis)

- **One Apple app** (macOS now; iOS/iPadOS a separate future epic — §5.8 / follow-up).
- **Cloudflare Workers only** for v1 deploy; provider independence via a post-v1
  self-hostable container (§5.5).
- **Social/protocol layer = first-party [`@dwk/workers`](https://github.com/davidwkeith/workers)**,
  composed as a per-site Worker — integration, not greenfield (§5.2).
- **Migration/import dropped from v1** (§5.4).
- **Audiences:** individuals *and* small businesses, one product (§4.1).
- **Design principle:** define each content type's schema once (Zod) → project to
  Astro types (editing) + microformats2 (federation) + schema.org JSON-LD (search).

## Dependency gating

`@dwk/workers` is `0.0.0`, unreleased, conformance pending. **V-2…V-5 are gated on a
stable, conformant release** (micropub.rocks / webmention.rocks). V-1 has no such
gate (Astro-native + small deps), so it starts immediately.

---

## V-0 — Finish the substrate (in flight, not part of this epic)

Continue Claude-removal + MAS + container runtime. Tracked elsewhere (#34, #59, #248).
Listed here only so the epic shows the starting line. **No new tasks.**

---

## V-1 — Typed content + feeds (no external gating; start now)

**Goal:** the owned IndieWeb site for both individuals and small businesses — typed
content objects with purpose-built editors, feeds, and dual mf2 + schema.org markup.

| # | Task | Area / files | Acceptance |
|---|---|---|---|
| 1.1 | **Content-type registry** in `AnglesiteCore` — each type declares Zod/frontmatter schema, mf2 mapping, schema.org mapping, editor descriptor, template. | extend `SiteContentGraph`, `ContentScaffold`, `ContentOperations` | A type is added by registering a descriptor; `list_content` + graph surface it; unit tests for ≥3 types. |
| 1.2 | **Personal types** — Note, Article, Photo, Album, Bookmark, Reply, Like (h-entry post types). | registry descriptors + Astro templates in `Resources/Template/` | Each type scaffolds, builds, and renders with correct mf2 classes. |
| 1.3 | **Business types** — Business Profile (→ `LocalBusiness` JSON-LD + h-card), Announcement/Offer, Event, Review/Testimonial, Listing/Product, Menu/Service (§4.1). | registry descriptors + templates | Business profile renders valid `LocalBusiness` JSON-LD; Review renders `Review`/`AggregateRating`. |
| 1.4 | **Per-type SwiftUI editors** — structured forms (photo picker, date+location for Event, in-reply-to URL for Reply, hours for Profile). | `AnglesiteApp` (new editor views), extend `FileEditorModel`/overlay | Each type has a form editor; round-trips to frontmatter; per-edit git commit preserved. |
| 1.5 | **Astro Content Collections + Zod schemas** per type in the template. | `Resources/Template/src/content.config.ts` | Collections validate; type errors surface at build; existing `blog` still works. |
| 1.6 | **Feeds** — RSS/Atom/JSON via `@astrojs/rss`, generated from collections. | `Resources/Template/src/pages/*.xml.js` | Valid feeds at build; one feed per relevant collection + a combined feed. |
| 1.7 | **microformats2 markup** in all type templates (h-entry/h-card/h-review/h-event). | `Resources/Template` layouts/components | Output validates against an mf2 parser; h-card present site-wide. |
| 1.8 | **schema.org JSON-LD** via `astro-seo-schema` + `schema-dts`. | template components | Rich-results test passes for Article/Event/Recipe/Review/LocalBusiness. |
| 1.9 | **App-Intent entities** for new types (extend `ContentEntities` pattern). | `AnglesiteIntents` | New types are Siri/Spotlight-matchable; intent tests added. |
| 1.10 | **Adopt-list deps wired** (`@astrojs/rss`, `astro-seo-schema`, `schema-dts`, `astro-embed`, pinned) + `pre-deploy-check` still green. | `Resources/Template/package.json` | `npm run build` + pre-deploy-check pass with new deps. |

---

## V-2 — Make it social, outbound (gated on `@dwk/workers` release)

**Goal:** publish once, syndicate everywhere; the invisible-publish pipeline.

**Prerequisite:** `@dwk/workers` stable (webmention/indieauth) + passing webmention.rocks.

| # | Task | Area | Acceptance |
|---|---|---|---|
| 2.1 | **Per-site Worker provisioning** — app flow to create D1/R2/KV bindings + deploy a composed `@dwk/workers` Worker, reusing `KeychainStore`/`CloudflareTokenVerifier`/`wrangler`. | `AnglesiteCore` (new provision command) | One action provisions + deploys a site's Worker; failures surfaced in debug pane. |
| 2.2 | **Webmention send** — on publish, parse outbound links, POST to targets via `@dwk/webmention`. | publish pipeline + Worker | Sending a post with links fires webmentions; verified against webmention.rocks. |
| 2.3 | **IndieAuth** — `@dwk/indieauth` endpoint wired; site is a valid IndieAuth identity. | Worker config | Sign-in flow works; token issuance verified. |
| 2.4 | **POSSE syndication** — cross-post to Mastodon/Bluesky on publish; record syndication URLs onto the canonical post; backfeed via `@dwk/webmention`. | publish pipeline + per-network adapters | A post syndicates and the `u-syndication` URLs are written back to source. |
| 2.5 | **Invisible-publish pipeline / queue** (§5.3) — debounce edits, rebuild, deploy → feed regen → webmention send → POSSE → notify; offline queue drains on reconnect; `pre-deploy-check` stays in path. | generalize `DeployCommand` into a state machine + background scheduling | Editing then going idle publishes automatically; offline edits queue and drain; security gate still blocks. |

---

## V-3 — Make it social, inbound (gated on `@dwk/workers` release)

**Goal:** receive comments/likes/replies on your own site; external clients can post.

**Prerequisite:** `@dwk/workers` stable + micropub.rocks/webmention.rocks; **data-canonicality decision (3.0).**

| # | Task | Area | Acceptance |
|---|---|---|---|
| 3.0 | **Decide received-interaction canonicality** (§6.2) — how the Worker's inbox store snapshots back into `Source/` git so #72 holds. | design decision + doc | Documented rule + schema for snapshotted interactions. |
| 3.1 | **Webmention receive** — `@dwk/webmention` receiver + async verify queue + inbox store. | Worker | Incoming webmentions verified + stored; passing webmention.rocks receiver tests. |
| 3.2 | **Micropub server** — `@dwk/micropub` create/update/delete; media → R2; typed objects wired so app-edit and Micropub-post are one operation on the repo. | Worker + content pipeline | A Micropub client posts a Note/Photo; it appears in `Source/` + on the site; passing micropub.rocks. |
| 3.3 | **WebSub hub** — `@dwk/websub` for subscriber notify on publish. | Worker | Subscribers receive HMAC-signed pings on publish. |
| 3.4 | **Render received interactions** — show replies/likes/reviews on the page (build-time pull and/or client fetch) + snapshot to git per 3.0. | template + sync | A received reply renders under the post and is committed to source. |

---

## V-4 — Federation + reader (gated on `@dwk/workers` release)

**Goal:** appear natively in the Fediverse; follow others.

**Prerequisite:** `@dwk/workers` activitypub/microsub conformant; V-3 backend live.

| # | Task | Area | Acceptance |
|---|---|---|---|
| 4.1 | **ActivityPub actor** — `@dwk/activitypub` inbox/outbox, HTTP Signatures, S2S delivery; site is followable from Mastodon. | Worker | A Mastodon user can follow the site and sees posts. |
| 4.2 | **Follower management UI** in the app. | `AnglesiteApp` | View/manage followers. |
| 4.3 | **Microsub reader** — `@dwk/microsub` subscriptions + normalized timeline; "follow" in the app. | Worker + app reader UI | Follow a feed; timeline renders in-app. |
| 4.4 | **WebFinger / identity** — `@dwk/webfinger`, `@dwk/host-meta`, optional did:web/passkeys. | Worker | `/.well-known/webfinger` resolves the site's identity. |

---

## V-5 — Communities + discovery (separate epic; gated on V-3/V-4 backend)

**Goal:** first-class groups; opt-in discovery. **Backend already exists in `@dwk/workers`** (ActivityPub Groups + ATProto) — this phase is UX + content modeling, not infrastructure. **Needs its own design spike before tasking.**

| # | Task | Area | Acceptance |
|---|---|---|---|
| 5.0 | **Communities design spike** — group content model, moderation/membership/roles, canonical-content story for multi-member content (§6.2 multiplied). Lead with ActivityPub Groups (ATProto PDS is exploratory). | design doc | Spike doc + decision on group backend + content mapping. |
| 5.1 | **Group provisioning + membership UX.** | app + Worker | Create a group; members join/leave; roles enforced. |
| 5.2 | **Discussion / announcements / events / gallery** mapped onto typed objects. | content pipeline | Group content publishes + federates. |
| 5.3 | **Moderation tooling.** | app | Report/remove/ban flows. |
| 5.4 | **Discovery (opt-in, open-data)** — consume existing open networks (Fediverse discovery, webrings) before building any directory. | research + thin integration | A user can find related sites/groups without a new centralized index. |

---

## Cross-cutting decisions (do early)

| # | Task | When |
|---|---|---|
| C.1 | **Adopt IndieWeb as the explicit content + protocol model** — keystone decision; rewrite content-graph/template story around h-entry post types. | before V-1 build |
| C.2 | **`@dwk/workers` integration seam + release tracking** — pin versions; track conformance milestones as V-2/V-3 prerequisites; stand up the "provision + deploy a per-site Worker" seam. | parallel with V-1 |
| C.3 | **Received-interaction data-canonicality decision** (= task 3.0, surfaced early). | before V-3 |

---

## Reviewer follow-ups (file as standalone issues)

| # | Task |
|---|---|
| F.1 | **Rename integration-wizard Bucket 5 `Syndicate`** (AI copy variants) → `repurpose`/`variant` so it stops colliding with POSSE syndication (§5.2). |
| F.2 | **iOS/iPadOS epic** — dedicated design doc + issue: scene/navigation model, remote Cloudflare runtime (#66/#71), separate App Store submission. Not free-by-shared-code; no earlier than V-3/V-4 era (§5.8). |
