# C.2: `@dwk/workers` Integration Seam + Release Tracking

**Date:** 2026-06-29  
**Status:** Decided  
**Part of:** #340 (cross-cutting decisions), #334 (pivot epic)  
**Prerequisite for:** V-2.1 (#353, per-site Worker provisioning)

---

## Decision

Anglesite integrates `@dwk/workers` as its social/protocol backend by **composing `@dwk/*` packages into a per-site Cloudflare Worker** deployed alongside the static site. The integration is version-pinned and conformance-gated.

### Integration model

```
┌─────────────────────────────────────────────────┐
│ Per-site Cloudflare Worker                       │
│                                                  │
│   worker.ts (entry point)                        │
│     ├── @dwk/indieauth  → /.well-known/indieauth│
│     ├── @dwk/webmention → /webmention            │
│     ├── @dwk/micropub   → /micropub              │
│     ├── @dwk/websub     → /.well-known/websub    │
│     └── env.ASSETS      → /* (static fallback)   │
│                                                  │
│   Bindings:                                      │
│     D1 "DB"    — social data (mentions, tokens)  │
│     R2 "MEDIA" — uploaded media (micropub)       │
│     KV "CACHE" — transient caches (optional)     │
└─────────────────────────────────────────────────┘
```

Each `@dwk/*` package exports a `createXxx({ baseUrl, ... })` factory returning a `fetch`-compatible handler. The Worker entry point routes by path prefix, falling through to static assets for everything else.

### Version pinning

`Resources/Template/worker/workers-version.json` declares the expected `@dwk/workers` version range. The app reads this to:
- Install the correct versions during scaffold (`npm install @dwk/webmention@^x.y`)
- Warn if a site's installed versions are outdated
- Gate social feature enablement on minimum versions

### Conformance gating

Social features are phased and each phase is gated on `@dwk/workers` conformance:

| Phase | Required packages | Conformance bar |
|---|---|---|
| V-2 | `@dwk/webmention`, `@dwk/indieauth` | Integration passing + all suites passing |
| V-3 | + `@dwk/micropub`, `@dwk/websub` | Same |
| V-4 | + `@dwk/activitypub`, `@dwk/microsub`, `@dwk/webfinger` | Same |

`WorkersConformanceReader` (in `AnglesiteCore`) parses the monorepo's `conformance/status.json` and `WorkersConformanceStatus.gateStatus(for:)` reports readiness. Until a phase's packages are all release-ready, the app does not offer that phase's features in the UI.

### Provisioning sequence (V-2.1 — #353)

When the user enables social features for a site:

1. App reads the Cloudflare API token (existing `DeployCommand.keychainTokenSource`)
2. App resolves the site's zone (existing `CloudflareReading.resolveZoneID`)
3. App creates the D1 database (`{siteName}-social`) via CF API → new `CloudflareWriting.createD1Database`
4. App creates the R2 bucket (`{siteName}-media`) if micropub is enabled → new `CloudflareWriting.createR2Bucket`
5. App writes `wrangler.toml` with filled binding IDs → `WorkerComposition.generateWranglerToml`
6. App scaffolds `worker/worker.ts` with the enabled imports
7. `npm install` the pinned `@dwk/*` packages
8. Deploy via `wrangler deploy` (existing `DeployCommand`)

Steps 3–7 are the new work in V-2.1. Steps 1–2 and 8 use existing infrastructure.

### What this task ships

- `WorkersConformanceReader` + `WorkersConformanceStatus` (Swift, AnglesiteCore)
- `WorkerComposition` (Swift, wrangler.toml generator)
- `worker/worker.ts` stub (template resource)
- `worker/wrangler.toml.template` (reference)
- `worker/workers-version.json` (version pin)
- This decision document

---

## Rationale

### Why pin versions?

`@dwk/workers` is a pre-release monorepo. Anglesite scaffolds a `package.json` (step 7 above) and must specify package versions to install. Without a pin, every scaffold would grab whatever is latest at npm — conflicting versions between sites, lost reproducibility, and no way for users to track which versions were tested with which app releases.

By committing `workers-version.json` alongside the template, Anglesite guarantees:
- Every site scaffolded from this template installs the same versions.
- The app can warn when a site's installed versions drift (e.g. user `npm update`d manually).
- Version bumps are explicit: a PR to the app repo that updates the pin coincides with app version notes and conformance docs.

### Why conformance-gate?

`@dwk/webmention` and `@dwk/indieauth` are integration-tested against Anglesite's architecture. Until both have shipped a release with conformance passing, the app offers no social UI. The conformance check (`WorkersConformanceStatus.gateStatus(for:)`) reads the monorepo's published `conformance/status.json` at build/provision time.

**V-2** (webmention + indieauth) ships when both packages conform.  
**V-3** adds micropub + websub when those conform.  
**V-4** adds ActivityPub + Microsub + WebFinger when those conform.

This decouples app releases from package readiness and prevents premature/incomplete feature rollouts.

### Why per-site Workers?

Per-site deployment means:
- Each site's D1 database is isolated (no multi-tenant state collision).
- R2 media uploads are scoped (each site's `{siteName}-media` bucket).
- KV caches are per-site (webmention queue, IndieAuth session store).
- Bindings are static — the Worker doesn't fetch/compute them at runtime.

Alternative: centralized Worker + routing. Rejected because:
- Centralized auth/session state is a single point of failure.
- Multi-tenant D1 partitioning is complex.
- Users expect to own their site's data.

### Why factory-pattern composition?

Each `@dwk/*` package (indieauth, webmention, micropub, websub, etc.) exports a factory `createXxx({ baseUrl, ... })` that returns a `fetch`-compatible handler. The Worker entry point imports, instantiates, and routes:

```typescript
import { createIndieAuth } from "@dwk/indieauth";
import { createWebmention } from "@dwk/webmention";

const indieauth = createIndieAuth({ baseUrl });
const webmention = createWebmention({ baseUrl });

export default {
  async fetch(request, env, ctx) {
    const url = new URL(request.url);
    if (url.pathname.startsWith("/.well-known/indieauth"))
      return indieauth.fetch(request, env, ctx);
    if (url.pathname.startsWith("/webmention"))
      return webmention.fetch(request, env, ctx);
    return env.ASSETS.fetch(request);
  }
};
```

Benefits:
- Packages are self-contained; no global state or module registration.
- Composition is explicit and human-readable in `worker.ts`.
- Feature enablement is a simple `npm install` + import toggle.
- The Worker stub (`Resources/Template/worker/worker.ts`) is manageable and auditable.

---

## Implementation: V-2.1 (#353)

The provisioning flow runs when the user clicks "Enable Social Features" in the Anglesite UI:

1. **Authorize** (existing): Read Cloudflare token via `DeployCommand.keychainTokenSource`.
2. **Resolve zone** (existing): `CloudflareReading.resolveZoneID(domain)` → zone ID.
3. **Create D1** (new): `CloudflareWriting.createD1Database(zone, siteName)` → database_id.
4. **Create R2** (new, if micropub enabled): `CloudflareWriting.createR2Bucket(zone, siteName)` → bucket_name.
5. **Write wrangler.toml** (new): `WorkerComposition.generateWranglerToml(siteName, features)` → wrangler.toml with filled binding IDs.
6. **Scaffold worker.ts** (new): Conditionally import enabled packages (indieauth, webmention, micropub, websub).
7. **Install packages** (new): `npm install` the pinned versions from `workers-version.json`.
8. **Deploy** (existing): `wrangler deploy` (via existing `DeployCommand`).

### Version pinning in implementation

When Anglesite scaffolds or re-provisions a Worker, it reads `Resources/Template/worker/workers-version.json` and:

- Inserts `^{major}.{minor}.{patch}` for each required `@dwk/*` package into `package.json`.
- Runs `npm install` to lock versions in `package-lock.json`.
- User can later `npm update` manually (pins are only suggestions at scaffold time).
- Anglesite warns if a site's locked versions are older than the template's pin (version drift).

### Conformance check at provision time

Before offering "Enable Social Features," the app:

1. Reads `WorkersConformanceReader` from the bundled plugin (same channel as the plugin MCP server).
2. Calls `WorkersConformanceStatus.gateStatus(for: .v2)` (or .v3, .v4, etc.).
3. If status is not `.released`, shows a "Not yet available" message in the UI.
4. Only shows UI controls for features with `.released` status.

---

## Files and ownership

| File | Owner | Purpose |
|---|---|---|
| `Resources/Template/worker/worker.ts` | Anglesite app | Per-site Worker entry point (stub, filled by V-2.1) |
| `Resources/Template/worker/wrangler.toml.template` | Anglesite app | wrangler.toml template (reference) |
| `Resources/Template/worker/workers-version.json` | Anglesite app | Version pin (read at scaffold/provision time) |
| `conformance/status.json` (monorepo) | @dwk/workers | Conformance status per package/phase (read by app at build time) |
| `WorkersConformanceReader` | Anglesite app | Reads conformance/status.json |
| `WorkerComposition` | Anglesite app | Generates wrangler.toml with bindings |
| `@dwk/indieauth`, `@dwk/webmention`, etc. | @dwk/workers monorepo | Social protocol implementations |

---

## Conformance status tracking

The app bundles the plugin, which includes the monorepo's `conformance/status.json`. Example structure:

```json
{
  "phases": {
    "v2": {
      "packages": ["@dwk/indieauth", "@dwk/webmention"],
      "status": "released"
    },
    "v3": {
      "packages": ["@dwk/micropub", "@dwk/websub"],
      "status": "in-progress"
    },
    "v4": {
      "packages": ["@dwk/activitypub", "@dwk/microsub", "@dwk/webfinger"],
      "status": "planned"
    }
  }
}
```

`WorkersConformanceStatus.gateStatus(for:)` returns:
- `.released` — all packages for this phase conform and are shipped.
- `.inProgress` — one or more packages still in development/testing.
- `.planned` — phase not yet targeted.

---

## Open questions and future work

1. **KV binding for caches:** The diagram shows optional KV. V-2.1 will define if KV is auto-provisioned or user-optional.
2. **Secrets (API keys, webhook tokens):** V-2.1 will define how the app injects secrets into wrangler.toml env vars or Wrangler secrets.
3. **Worker size/timeout:** Cloudflare limits Worker bundle size and execution time. If composition grows, we may need to split into multiple Workers or lazy-load handlers.
4. **Backwards compatibility:** If a site was scaffolded with an old pin (e.g. `@dwk/webmention@0.0.1`) and the user opens it in a newer app version (pin is now `@dwk/webmention@0.1.0`), the app should warn but allow manual `npm update`.

---

## See also

- #340 — C.2 epic (Worker integration decisions)
- #334 — Pivot epic (phased social feature rollout)
- #353 — V-2.1 (per-site Worker provisioning implementation)
- Task 2 — `WorkersConformanceReader` + `WorkersConformanceStatus` design
- Task 3 — `WorkerComposition` design
- `@dwk/workers` README and conformance docs (monorepo)
