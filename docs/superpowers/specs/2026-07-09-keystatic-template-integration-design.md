# Keystatic template integration — `inbox` and `membership` (#462)

**Issue:** [#462](https://github.com/Anglesite/Anglesite-app/issues/462) — 19 of ~21 planned
integrations are merged; `inbox` and `membership` are the last two, deferred because both are
Keystatic-backed and Keystatic was never wired into `Resources/Template`. This spec adds that
foundation, then builds `inbox`/`membership` on top of it.

> **Post-implementation note (PR #590):** two things below shipped differently than planned, both
> discovered mid-implementation and confirmed against the real installed packages (see the
> implementation plan's Self-Review Notes for the full account):
> - `astro.config.ts` does **not** mount `keystatic()`/`react()` unconditionally as §1 describes.
>   Astro's real integration registers server routes at build time, which would have silently
>   broken the static Cloudflare Workers deploy — the shipped version gates both behind
>   `process.argv[2] === "dev"` so they're never registered outside `astro dev`.
> - `content.config.ts` does **not** gain wizard-toggled anchors for `inbox` as §2 describes.
>   `inbox` has no Astro collection at all (nothing renders it publicly, so it doesn't need one);
>   only `membership`'s `members` collection was added, and unconditionally (like
>   `blog`/`events`/`reviews`), not via anchor injection. See §3/§4 below for the schema each
>   integration's Keystatic `collection()` actually uses, which also required a `slugField` +
>   `fields.slug()` on the entry's slug field and `isRequired: true` on both date fields — neither
>   anticipated below.

## Context

- Keystatic is explicitly a **Bucket 2** tool in the Claude-removal roadmap
  (`docs/superpowers/specs/2026-06-20-claude-code-removal-roadmap-design.md:116`) — JS-ecosystem,
  kept because reimplementing it natively buys nothing. It is not a candidate for a Swift port.
- The **Bucket 3 wizard framework** (`Sources/AnglesiteCore/IntegrationDescriptor.swift`,
  `IntegrationCatalog.swift`) is deliberately zero-npm-dependency today: every existing integration
  (`pwa`, `tracking`, `menu`, …) only copies static files/snippets and writes config — no
  `package.json` changes, no build-time npm installs triggered by toggling a wizard. Keystatic
  can't fit that mold; it's a real npm package with a React-based admin UI.
- The container already runs `npm install` on every boot (`hydrate.sh`), so a dependency merely
  *present* in `package.json` from scaffold time needs no new "install at apply-time" machinery —
  this is the basis for treating Keystatic as always-present rather than toggle-installed.
- `Resources/Template/scripts/pre-deploy-check.ts` already hard-blocks any `/keystatic` or
  `/api/keystatic` route found in `dist/` output (`BLOCKED_ROUTES`, existing code, unrelated to
  this change) — a deploy-blocking error, not a warning. Keystatic's Astro integration only
  registers its admin route under `astro dev`, not `astro build`, so in normal operation the route
  never reaches `dist/` and this check is defense-in-depth, not the primary exclusion mechanism.
  **This assumption must be verified against the real package during implementation** — if
  `@keystatic/astro` turns out to emit a build-time route, every deploy on a Keystatic-enabled site
  would fail and the design needs a build-time exclusion step instead.
- `Resources/Template/src/content.config.ts` already defines Astro content collections (`blog`,
  `notes`, `articles`, …) via `defineCollection` + the `glob` loader reading Markdown under
  `src/content/<name>/`. Keystatic's `local` storage mode writes directly to files in the repo, so
  new Keystatic collections can populate this same file layout and be exposed to the frontend
  through this same file, following its established pattern.
- Runtime form-submission capture (a visitor-facing form POSTing into `inbox` live) is explicitly
  **out of scope** for this spec. The per-site Worker
  (`Resources/Template/worker/worker.ts`) that would receive such a POST is currently a placeholder
  built to compose `@dwk/*` packages that don't exist yet (`@dwk/indieauth`, `@dwk/webmention`,
  etc. — issue #353 only shipped the D1/KV/R2 *provisioning* flow, not the endpoint composition
  layer). Building a one-off endpoint outside that intended architecture, plus a KV staging store,
  plus an app-side pull-and-commit-into-git pipeline, plus spam/abuse handling for a public
  unauthenticated write endpoint, is a second, largely independent feature. It gets its own
  follow-up issue (filed alongside this spec) rather than being designed here.

## Design

### 1. Keystatic foundation (always-present, dormant)

- `package.json`: add `@keystatic/core`, `@keystatic/astro`, `@astrojs/react`, `react`, `react-dom`
  (Keystatic's Astro integration mounts a React admin UI at `/keystatic`; exact version pins
  confirmed against the npm registry during implementation, including Astro 6 compatibility).
- `astro.config.ts`: add `keystatic()` and `react()` to the `integrations` array, alongside the
  existing `anglesiteHarness()`. This is a direct template edit (not wizard-toggled) since the
  integration must always be mounted for any site's Keystatic admin route to work in dev.
- New `Resources/Template/keystatic.config.ts` at the project root:
  ```ts
  import { config } from "@keystatic/core";

  export default config({
    storage: { kind: "local" },
    collections: {
      // anglesite:keystatic-collections
    },
    singletons: {
      // anglesite:keystatic-singletons
    },
  });
  ```
  `storage: { kind: "local" }` writes straight to files in the repo — no cloud account, no GitHub
  App, consistent with "git is the source of truth everywhere."
- No `ProjectValidator` changes — `keystatic.config.ts` isn't required for project validity, it's
  just another committed template file.
- No `pre-deploy-check.ts` changes — its existing `BLOCKED_ROUTES` check already covers this.

### 2. `content.config.ts` gains two anchors

```ts
// anglesite:collection-defs

export const collections = { blog, notes, …, reviews,
  // anglesite:collections
};
```

Matches the existing `// anglesite:imports`-style marker convention in `BaseLayout.astro`. Toggled
integrations inject new `const x = defineCollection(...)` blocks at the first anchor and append
`x,` at the second, using the existing `injectAtAnchor` operation — no new `Operation` case needed.

### 3. `inbox` integration

- `IntegrationID.inbox` case (already reserved in the enum's design intent per the roadmap spec).
- No provider, no required fields.
- Operations:
  - `injectAtAnchor` into `keystatic.config.ts`'s `// anglesite:keystatic-collections` anchor:
    a `collection()` block — `path: "src/content/inbox/*"`, fields `subject` (text), `from`
    (text), `receivedDate` (date), `status` (select: new / reviewed / archived, default new),
    `message` (markdoc).
  - `injectAtAnchor` into `content.config.ts`'s two anchors: matching `defineCollection` with a
    Zod schema (`subject: z.string()`, `from: z.string()`, `receivedDate: z.coerce.date()`,
    `status: z.enum(["new", "reviewed", "archived"]).default("new")`) and `inbox,` in the export.
  - `copyFile` a short `docs/inbox-setup.md`: explains the owner's workflow today (open the site in
    Anglesite, use the Keystatic admin UI in dev to add an entry — e.g. paste in a message that
    came by email) and links the future runtime-capture follow-up issue.
- No CSP domain changes (no external endpoint in this pass).

### 4. `membership` integration

- `IntegrationID.membership` case.
- No provider, no required fields (or possibly an optional "directory title" text field, TBD at
  implementation time following the `redirects`/`menu` minimal-fields pattern).
- A **public member directory** — name, role/bio, joined date, optional photo, optional links —
  not access-gated content. Gating needs an auth backend, which is materially bigger scope and
  overlaps with the existing paid-tier commerce integrations (`paddle`, `lemonSqueezy`, …); it's
  not part of this spec.
- Operations: same shape as `inbox` — Keystatic `collection()` + matching `defineCollection`, plus
  a `src/pages/members.astro` page (via `copyFile`) that renders the directory, and a
  `MemberCard.astro` component.

### 5. Follow-up issue

File a new issue (referenced from `inbox-setup.md`) for the Worker-based runtime submission
pipeline: visitor form → Worker endpoint → staged in KV → app pulls staged entries and commits them
into the site's git working copy the next time it opens (reusing the existing hydrate-from-repo /
push-back-to-repo flow — no long-lived git-write credentials in the Worker). Explicitly blocked on
`@dwk/workers` existing, since the Worker composition layer worker.ts expects is still a
placeholder.

## Testing

- `Tests/AnglesiteCoreTests/IntegrationCatalogTests.swift`: descriptor shape tests for `inbox` and
  `membership`, following the existing per-integration test pattern.
- `Tests/AnglesiteCoreTests/IntegrationTemplateAssetsTests.swift`: already validates that every
  `TemplateRef` an `IntegrationDescriptor` points at actually exists in `Resources/Template` — the
  new `copyFile` targets (`docs/inbox-setup.md`, `members.astro`, `MemberCard.astro`) get covered
  automatically once added, no new test infra needed.
- Template side: `astro check` (already run in `npm run build`) type-checks `content.config.ts`
  and `keystatic.config.ts` against real Zod/Keystatic schemas — verifies the anchor-injected code
  is syntactically and structurally valid once both integrations are toggled on in a scratch site.
- Manual GUI smoke (per this repo's convention for template/wizard changes): scaffold a new site,
  toggle `inbox` and `membership` on, open `astro dev` in the container, confirm `/keystatic` loads
  and both collections are editable; confirm `npm run build` + `pre-deploy-check` both stay clean
  (no blocked route, no type errors).

## Alternatives rejected

- **Toggle-installed Keystatic** (only enters `package.json` when `inbox`/`membership` is first
  turned on): would need a new `addDependency` + `modifyAstroConfig` `Operation` type and an
  npm-install step in the apply pipeline that doesn't exist today. Always-present is simpler and
  free, since the container already runs `npm install` on every boot regardless of what's in
  `package.json`.
- **Membership as access-gated content**: needs an auth backend (sessions, paywall, or a
  third-party gating service) — a separate, much larger feature, and one that already has a
  natural home once the commerce integrations' paid-tier work matures, rather than being bolted
  onto this pass.
- **Full runtime capture in this pass**: rejected per the Context section — the Worker composition
  layer it depends on doesn't exist yet; building a one-off endpoint outside that architecture
  would likely be throwaway work once `@dwk/workers` lands.
