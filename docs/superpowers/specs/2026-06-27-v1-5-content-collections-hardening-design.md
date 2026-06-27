# V-1.5: Astro Content Collections + Zod schemas — hardening

**Issue:** #347 (V-1.5) · Epic: #335 (V-1) · Plan task 1.5
**Date:** 2026-06-27
**Type:** App-only change (no plugin/MCP coordination)

## Context

The collection definitions and per-type Zod schemas that #347 nominally asks for
already exist in [`Resources/Template/src/content.config.ts`](../../../Resources/Template/src/content.config.ts).
They were added incidentally by the V-1.2 (#378) and V-1.3 (#387) vertical slices,
and #387 also shipped a one-directional **drift guard**
([`Tests/AnglesiteCoreTests/ContentConfigDriftTests.swift`](../../../Tests/AnglesiteCoreTests/ContentConfigDriftTests.swift))
asserting every collection-backed registry type appears verbatim in the config.

The canonical source of truth is the Swift `ContentTypeRegistry`
([`Sources/AnglesiteCore/ContentTypeRegistry.swift`](../../../Sources/AnglesiteCore/ContentTypeRegistry.swift)) —
the "one schema, three projections" vocabulary. `content.config.ts` is its
frontmatter projection.

So #347 is a **hardening / completion** task, not net-new collections. Two
acceptance criteria are not yet fully met:

1. **"type errors surface at build"** — the build is plain `astro build`. Zod
   *value* errors surface, but TypeScript *type* errors (a template reading a
   field absent from the schema) do not: there is no `@astrojs/check` dependency,
   and the `check` npm script only runs the header pre-deploy check.
2. **"collections validate"** — schemas are non-strict (`z.object({…})`), so a
   typo'd frontmatter key is silently dropped rather than flagged. The drift
   guard is also one-directional: it cannot catch an *orphan* collection present
   in the config but absent from the registry.

## Goals

- Type errors (not just value errors) fail `npm run build`.
- Unknown frontmatter keys fail the build (`.strict()` schemas).
- The drift guard locks config↔registry in **both** directions, with the one
  intentional non-registry collection (`blog`) documented in an explicit allowlist.

## Non-goals (separate issues)

- `businessProfile` page-singleton validation — **#388**
- microformats2 markup in templates — **#349**
- schema.org JSON-LD — **#350**

## Design

### Component 1 — Type-check wiring

`npm run build` is the single canonical build entry, invoked by `DeployCommand`,
`AuditCommand`, and `DefaultHealthCheckRunner`. Wiring `astro check` into the
`build` script makes type errors surface across the deploy, audit, and
health-check paths in one move; the app already surfaces build failures.

- Add `@astrojs/check` and `typescript` to the template **devDependencies** in
  [`Resources/Template/package.json`](../../../Resources/Template/package.json);
  regenerate `package-lock.json`.
- Change the `build` script: `astro build` → **`astro check && astro build`**.
- `node_modules` is gitignored (installed, not committed), so this is a
  manifest-only change; `npm install` (scaffold/build time) pulls the new deps.

**Alternative considered:** put `astro check` only in the `check` npm script
(the pre-deploy gate). Rejected — the acceptance says "at build," and the `build`
script reaches more call sites (deploy + audit + health), giving stronger
coverage.

### Component 2 — Strict schemas

- Append `.strict()` to every `z.object({…})` in `content.config.ts`, including
  the legacy `blog` collection.
- Audit the `hello-*.md` example entries (and `blog/welcome-to-your-blog.md`) for
  stray frontmatter keys; fix or remove any that `.strict()` would now reject so
  the template still builds clean.
- Update the drift guard's `canonicalBlock` generator to emit `.strict()` so the
  verbatim registry↔config match still holds after the change.

### Component 3 — Bidirectional drift guard

Extend `ContentConfigDriftTests.swift`:

- Add an explicit allowlist constant, e.g.
  `static let nonRegistryCollections: Set<String> = ["blog"]`, with a comment
  explaining `blog` is the template's example collection and has no registry
  descriptor.
- Add a test that parses the `export const collections = { … }` line, extracts
  the collection identifiers, and asserts the set **equals**
  `{builtin collection ids} ∪ nonRegistryCollections` — failing on an orphan
  collection (in config, not in registry) as well as a missing one.
- Keep the existing forward check (each builtin collection block appears verbatim).

## Testing & verification

- `swift test` — the bidirectional, `.strict()`-aware drift guard passes; existing
  forward checks still pass.
- `cd Resources/Template && npm install && npm run build` — confirms `astro check`
  passes against the template and `.strict()` schemas do not break the example
  content.
- `pre-deploy-check.test.ts` is untouched and still passes.

## Risks

- **Strict schemas vs. example content:** an existing `hello-*.md` with an extra
  key would break the build. Mitigated by the build-verification step above —
  audit and fix before finishing.
- **`astro check` runtime cost:** adds a type-check pass to every `npm run build`.
  Acceptable for a static site of this size; it is the price of the acceptance
  criterion.
