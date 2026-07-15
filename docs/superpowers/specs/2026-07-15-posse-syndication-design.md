# POSSE Syndication + Source Backfeed — Design

**Date:** 2026-07-15
**Status:** Decided
**Issue:** #356 (V-2.4)

## Decision

Ship direct, deterministic Mastodon and Bluesky posting after a successful deploy. An entry opts in
with `posse: [mastodon, bluesky]`; Anglesite never posts every entry implicitly. It derives bounded
copy from `posseText`/`socialText`, then description/body, always preserving the canonical URL.

The parent epic's `@dwk/workers` gate remains pending, but no unstable package API is needed here:
Mastodon exposes `POST /api/v1/statuses`; Bluesky exposes `createSession` + `createRecord`.
`@dwk/webmention` remains the receiving/backfeed substrate. The app reuses its native Webmention
sender only after a later deploy makes the written `u-syndication` link publicly verifiable.

## Persistence and idempotency

- Non-secrets live in optional `SiteSettings` fields (`mastodonBaseURL`, `blueskyIdentifier`,
  `blueskyPDSURL`). Tokens/app passwords use site-UUID-scoped secret-store accounts. Environment
  variables are a development/automation fallback.
- `Config/posse-syndication.json` records each canonical URL + platform + returned social URL.
- Mastodon gets a stable `Idempotency-Key`; Bluesky gets a stable `rkey` and treats conflict as an
  already-created record.
- The returned URL is saved to the ledger before source write-back. A crash or write failure is
  repaired from the ledger next deploy without posting twice.
- Source write-back uses the existing deduplicating `SyndicationFrontmatter` implementation.

## Template contract

All strict Astro collection schemas accept the opt-in/copy/syndication fields. Entry layouts render
the returned URLs as real `u-syndication` links, keeping source, built HTML, and Microformats2 in
agreement.

## Failure policy

POSSE is fire-and-forget after deploy success. Missing credentials, individual platform failures,
ledger failures, and write-back failures go to `LogCenter` under `posse:<siteID>` and never change a
successful deploy into a failed one. Failed remote posts are not ledgered and retry on the next
deploy.

## Non-goals

- Media upload and thread construction.
- Generative social copy (the separate repurpose capability).
- A credentials UI; this vertical slice establishes the portable settings/secret-store contract.
- Inbound interaction rendering, owned by V-3.
