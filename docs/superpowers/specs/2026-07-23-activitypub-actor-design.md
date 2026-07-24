# V-4.1: ActivityPub actor — design

Issue: [#363](https://github.com/Anglesite/Anglesite-app/issues/363) (part of epic [#338](https://github.com/Anglesite/Anglesite-app/issues/338), V-4 Federation + reader).

## Goal

Make a site a followable Fediverse actor: a Mastodon user can follow the site
and sees its posts. `@dwk/activitypub` (published `0.1.0-beta.5` on npm)
implements the actual ActivityPub protocol — inbox/outbox, follower
collections, HTTP Signatures, signed S2S delivery, all behind a per-actor
Durable Object. This app's job is composition: wire the package's declared
resources into the generated `wrangler.toml`, import it into the template's
`worker/worker.ts`, and let the existing generic Workers-tab toggle activate
it (its catalog binding is `settingsActivated`, the same mechanism
`@dwk/micropub` already uses — no new Settings screen needed just to turn it
on).

## Scope

**In scope:**

- Compose `@dwk/activitypub` into the per-site Worker (`wrangler.toml` DO
  binding + migration, `worker.ts` wiring) behind the existing Workers-tab
  toggle.
- Fixed single actor per site: username `"site"`, display name from
  `SiteSettings.displayName` (existing field, falls back to the site name), a
  generic fixed summary string. No new Settings field for identity.
- App-generated RSA keypair (2048-bit; PKCS#8 private / SPKI public PEM — the
  formats `@dwk/activitypub` requires for WebCrypto), persisted in Keychain
  per-site, pushed to Cloudflare as `AP_PRIVATE_KEY`/`AP_PUBLIC_KEY` secrets
  during provisioning.
- Micropub → ActivityPub fan-out: a successful Micropub **create** triggers an
  in-process call to the actor's owner-publish endpoint, so newly published
  posts land in the outbox as `Note` activities. This is what satisfies
  "sees posts" for this slice.
- `WorkersConformanceStatus.phaseRequirements[.v4]` already lists
  `@dwk/activitypub` — `WorkerActivation.conformanceAdvisory` covers it with
  no new code.

**Explicitly out of scope (tracked separately, not blocking this issue):**

- WebFinger (`.well-known/webfinger`, so `@user@domain` search resolves) —
  issue #364 / epic sub-task 4.4. Mastodon can still follow by pasting the
  actor URL directly into search, so this doesn't block acceptance here.
- Follower management UI — epic sub-task 4.2.
- Microsub reader — epic sub-task 4.3.
- Syncing a site's pre-existing content-collection posts (anything published
  before ActivityPub was activated, or authored outside Micropub) into the
  outbox — filed as [#926](https://github.com/Anglesite/Anglesite-app/issues/926)
  against epic #338. Materially bigger scope (a build/deploy-time content
  sync) than this slice.

## `@dwk/activitypub` contract (as published)

```ts
import { createActivityPub, ActivityPubObject } from "@dwk/activitypub";

const activitypub = createActivityPub({
  baseUrl: "https://example.com",
  actor: { username: "site", name: "...", summary: "..." },
  publicKeyPem: env.AP_PUBLIC_KEY,     // SPKI PEM
  privateKeyPem: env.AP_PRIVATE_KEY,   // PKCS#8 PEM, secret binding
  publishToken: env.AP_PUBLISH_TOKEN,  // optional: enables POST <actor>/outbox
  software: { name: "anglesite", version: "..." },
});

// GET  /users/site                      → actor document
// GET  /users/site/{outbox,followers,following}[?page=N]
// POST /users/site/inbox                → signed S2S delivery
// GET  /.well-known/nodeinfo, /nodeinfo/2.1
return activitypub(request, env, ctx);

export { ActivityPubObject };
```

Catalog entry (`catalog.json`, already published, no `requires`):

```json
{
  "id": "activitypub",
  "package": "@dwk/activitypub",
  "group": "social",
  "binding": { "kind": "settingsActivated" },
  "resources": [
    { "type": "durable-object", "binding": "ACTOR", "className": "ActivityPubObject", "sqlite": true }
  ],
  "routes": [
    { "path": "/users/", "match": "prefix", "methods": ["GET", "POST"], "head": true, "handler": "createActivityPub" },
    { "path": "/inbox", "match": "exact", "methods": ["POST"], "handler": "createActivityPub" },
    { "path": "/.well-known/nodeinfo", "match": "exact", "methods": ["GET"], "head": true, "handler": "createActivityPub", "authorityBound": true },
    { "path": "/nodeinfo/", "match": "prefix", "methods": ["GET"], "head": true, "handler": "createActivityPub" }
  ]
}
```

## Wrangler composition (new resource kind: Durable Objects)

Following the precedent `indieauth`/`webmention`/`micropub` already set —
bespoke binding names are part of a package's public composition contract, so
`WorkerComposition` keys off the catalog id directly rather than growing
`WorkerDescriptor.Resources`'s generic `needsD1`/`needsKV`/`needsR2` flags:

- Add `WorkerComposition.activitypubWorkerID = "activitypub"` and a
  `hasActivityPub` check, mirroring `hasWebmentionReceive`/`hasMicropub`.
- When active, `generateWranglerToml` emits:

  ```toml
  [[durable_objects.bindings]]
  name = "ACTOR"
  class_name = "ActivityPubObject"

  [[migrations]]
  tag = "v1"
  new_sqlite_classes = ["ActivityPubObject"]
  ```

- Route claims for `run_worker_first` come directly from the catalog's
  already-published `routes` array for `activitypub` — no new route-claim
  modeling needed (#746's machinery is already generic).

## `worker.ts` wiring

- New import block: `createActivityPub`, `ActivityPubObject`, and its config
  types from `@dwk/activitypub`, alongside the existing
  `@dwk/indieauth`/`@dwk/webmention`/`@dwk/micropub` imports.
- `export { ActivityPubObject };` — required so wrangler can bind the
  Durable Object class from this script.
- New `WorkerEnv` fields, all optional (matching every other worker's
  "degrade gracefully rather than throw" convention in this file):
  `ACTOR?: DurableObjectNamespace`, `AP_PRIVATE_KEY?: string`,
  `AP_PUBLIC_KEY?: string`, `AP_PUBLISH_TOKEN?: string`.
- `handleActivityPub`, following `handleMicropub`'s shape: 503 when
  `ACTOR`/`AP_PRIVATE_KEY`/`AP_PUBLIC_KEY` aren't all bound, otherwise
  `createActivityPub({...}).(request, env, ctx)`.

## Keypair generation & storage

The one genuinely new capability here — no prior secret in this app has
needed real key material, only opaque tokens/passwords.

- New `AnglesiteCore` type (`ActivityPubKeyProvisioning`) using the Security
  framework (`SecKeyCreateRandomKey`, `kSecAttrKeyTypeRSA`, 2048-bit) to
  generate a keypair, then wrapping the raw PKCS#1 DER Security framework
  returns into the PKCS#8 (private) and SPKI (public) ASN.1 envelopes
  `@dwk/activitypub` requires for WebCrypto import. This is a standard
  fixed-prefix transformation for RSA (well-documented; not something Swift's
  Security framework does natively for export).
- Only the **private** key PEM is persisted; the public key is re-derived
  from it on demand (`SecKeyCopyPublicKey` + re-wrap as SPKI) so there is
  exactly one piece of stored state and no risk of the two drifting apart.
- Storage: Keychain, following the existing per-site-keyed pattern
  (`SecretAccounts.mastodonAccessToken(siteID:)`,
  `blueskyAppPassword(siteID:)`) — add
  `SecretAccounts.activityPubPrivateKeyPem(siteID:)`.
- **Generated once, lazily, inside `SocialWorkerProvisionCommand.provision()`**
  — the same place D1/R2/KV/Queue resources are created today — not at
  Workers-tab toggle-time. Toggling a worker only edits
  `SiteSettings.activeWorkerIDs`; all actual resource/secret creation happens
  during provision/deploy. The key is generated exactly once per site
  (checked via a Keychain read before generating) and never touched again on
  subsequent deploys — regenerating it would break federation trust with
  existing followers.
- Pushing the value to Cloudflare needs `wrangler secret put <NAME>`, which
  reads its value from stdin. The existing `SocialWorkerProvisionCommand.
  CommandRunner` closure (used for `d1 create`/`r2 bucket create`/etc.) has no
  stdin parameter, but `ProcessSupervisor` already supports this generically
  (`launch(attachStdin: true)` + `stdinWriter`, today used for MCP JSON-RPC
  framing). Secret provisioning uses that lower-level path directly, piping
  the PEM value straight into the child process's stdin — it never touches
  argv or an environment variable.

## Micropub → ActivityPub fan-out

- In `worker.ts`'s `handleMicropub`, after a successful **create** action
  (update/delete stay out of scope for v1), synthesize an internal
  `POST <actorIRI>/outbox` request carrying the `AP_PUBLISH_TOKEN` bearer
  header, and call the same `activitypub(request, env, ctx)` handler
  in-process — no network round-trip, same Worker script, same invocation
  this request is already inside.
- Content mapping: every fanned-out post becomes an AS2 `Note` (not
  `Article`) — the simplest, universally-supported choice for Mastodon
  interop — built from the Micropub post's `content`/`name` properties and
  the created post's URL (`Location` response header).
- Only fires when `AP_PUBLISH_TOKEN` is set (i.e. ActivityPub is actually
  active and provisioned) — activating Micropub alone with ActivityPub off
  never attempts to federate.
- Fan-out failure must never fail the Micropub create response (the post is
  already saved) — log and swallow, matching this file's existing
  degrade-gracefully convention.

## Testing

- `WorkerCatalogTests`: decoding the `activitypub` catalog entry — the new
  `durable-object` resource type must not break existing D1/KV/R2 decoding.
- `WorkerCompositionTests`: `generateWranglerToml` emits the
  `[[durable_objects.bindings]]` + `[[migrations]]` blocks when `activitypub`
  is active, omits them otherwise — mirrors the existing
  `hasWebmentionReceive`/`hasMicropub` test shape.
- New `ActivityPubKeyProvisioningTests`: generate a keypair, shell out to
  `openssl asn1parse`/`openssl rsa -check -noout` to confirm the PEM is valid
  PKCS#8/SPKI, and confirm the derived public key matches the private key
  (`openssl rsa -pubout` round-trip).
- `SocialWorkerProvisionCommandTests`: provisioning generates the key exactly
  once (idempotent across repeated `provision()` calls for the same site),
  and the `wrangler secret put` invocations carry the right stdin-piped
  values (via the existing fake-runner/fake-supervisor test doubles this file
  already uses for D1/R2/Queue).
- `worker.test.ts`: a new `describe("ActivityPub")` block mirroring the
  existing Micropub/Webmention groups — actor document served, 503 when
  unprovisioned, and a test that a Micropub create triggers a `Note` landing
  in the outbox.

## Follow-ups (not this issue)

- [#364](https://github.com/Anglesite/Anglesite-app/issues/364) — WebFinger.
- Epic #338 sub-task 4.2 — follower management UI.
- Epic #338 sub-task 4.3 — Microsub reader.
- [#926](https://github.com/Anglesite/Anglesite-app/issues/926) — sync
  pre-existing Astro content into the outbox.
