# C.1: Adopt IndieWeb as the Explicit Content + Protocol Model

**Date:** 2026-06-29
**Status:** Decided
**Part of:** #340 (cross-cutting decisions), #334 (pivot epic)
**Prerequisite for:** V-2 (social outbound), V-3 (social inbound), V-4 (federation)

---

## Decision

Anglesite adopts the **IndieWeb** content vocabulary and protocol stack as its
explicit content + protocol model. This is not a new direction — V-1 already
built the infrastructure — but a formal commitment that governs all future
content-type and federation work.

### What this means

1. **Content vocabulary = microformats2 post types.** Every content type in the
   `ContentTypeRegistry` maps to an mf2 root class (`h-entry`, `h-event`,
   `h-review`, `h-card`). The Zod schema in `content.config.ts` is the single
   source of truth; it projects three ways:
   - **Astro types** — editing + rendering (frontmatter → template)
   - **microformats2** — federation (h-entry classes in HTML)
   - **schema.org JSON-LD** — search (rich results)

2. **Protocol stack = IndieWeb + ActivityPub (via `@dwk/workers`).** The
   federation/interaction protocols are:
   - **Webmention** (send + receive) — the primary interaction primitive
   - **Micropub** (create/update/delete) — the posting API
   - **IndieAuth** (auth + identity) — the auth layer
   - **WebSub** (pub/sub notifications) — real-time subscriber notify
   - **ActivityPub** (federation) — Fediverse interop (V-4)
   - **Microsub** (reader) — feed consumption (V-4)

   All implemented by `@dwk/workers`, composed into a per-site Cloudflare Worker.
   Anglesite integrates, not builds.

3. **h-card as site identity.** The `personalProfile` / `businessProfile`
   singletons are the representative h-card, emitted in every page's footer.
   This is the identity Webmention, IndieAuth, and ActivityPub discover.

### What's already shipped (V-1)

| Layer | Status | Location |
|---|---|---|
| Content type registry (Swift) | ✅ Shipped | `Sources/AnglesiteCore/ContentTypeRegistry.swift` |
| Zod schemas (11 collections) | ✅ Shipped | `Resources/Template/src/content.config.ts` |
| mf2 templates (h-entry/h-event/h-review/h-card) | ✅ Shipped | `Resources/Template/src/layouts/` |
| schema.org JSON-LD | ✅ Shipped | `Resources/Template/src/lib/schema.ts` |
| RSS/Atom/JSON feeds | ✅ Shipped | `Resources/Template/src/pages/{rss,atom,feed}.*` |
| Per-type SwiftUI editors | ✅ Shipped | `Sources/AnglesiteApp/NewContentSheets.swift` |
| App-Intent entities | ✅ Shipped | `Sources/AnglesiteIntents/ContentEntities.swift` |
| Build-time mf2 validation | ✅ Shipped | `Resources/Template/scripts/check-microformats.ts` |

### What this decision enables

- **V-2:** Webmention send on publish. The mf2 markup is already the
  canonical source the sender parses to discover reply/like/bookmark targets.
- **V-3:** Micropub create/update/delete. The Zod schema is the contract
  between the Micropub endpoint and the content collection.
- **V-4:** ActivityPub. The h-card is the actor identity; h-entry posts
  federate as `Create`/`Update` activities.

### Design principles locked

- **One schema, three projections.** Every content type is defined once in Zod
  and projected to Astro types (editing), mf2 classes (federation), and
  schema.org JSON-LD (search). No duplication.
- **Static where possible, dynamic only for interaction.** Published content is
  static HTML with mf2 classes. The dynamic Worker handles *receiving*
  interactions (webmentions, micropub, inbox) — not *rendering* content.
- **No custom vocabulary.** We emit standard mf2 properties, not proprietary
  extensions. If a post type doesn't map cleanly to mf2, it's a signal we're
  inventing rather than adopting.
