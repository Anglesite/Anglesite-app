# Bucket 3 — Template Config Wiring (Design)

**Date:** 2026-06-21
**Status:** Design / approved — no implementation yet
**Issue:** #282 (follow-up to the Bucket 3 integration wizard framework, PR #283)
**Branch:** `feat/282-template-wiring`

## 1. Problem

The Bucket 3 framework (shipped on `main`) writes a site's integration config into `.site-config`
and copies/injects Astro components, but the **app-owned website template doesn't consume any of
it**. Verified on `main`:

- `Resources/Template/` has **no config bridge** — no `config.ts`, no `csp.ts`. `astro.config.mjs`
  is `defineConfig({})` and `scaffold.sh` only writes `ANGLESITE_VERSION` to `.site-config`.
- The scaffolded pages (`book.astro`, `donate.astro`) read `import.meta.env.BOOKING_*` /
  `DONATIONS_*`, which nothing populates — so they render no data.
- The floating-booking and giscus integrations inject `<BookingWidget>` / `<Comments>` into layouts
  via `injectAtAnchor` but never add the component `import` to the layout frontmatter — an Astro
  build error (C1).
- Inline booking drops the user's `eventSlug` (I4).

This spec makes the template **consume** the config the framework writes.

## 2. Approach (locked)

**`readConfig()` in Astro frontmatter + config-driven conditional render, with components copied
on-demand and their import + render injected into the layout at setup.**

- A build-time `readConfig(key)` helper reads the flat `.site-config`. Pages and the injected layout
  snippets read keys in frontmatter and conditionally render the component.
- **Components stay on-demand** — copied only when their integration is set up; a site never carries
  unused integration component files.
- Because a layout that renders `<BookingWidget>` must `import` it (and `tsconfig` is
  `astro/tsconfigs/strict` → `noUnusedLocals`), the import and the render are **injected into the
  layout at setup time**, alongside copying the component. No always-present component assets.

This resolves **C1** (the import is injected with the render), **I3** (a real build-time bridge via
`readConfig`), **I4** (`BOOKING_EVENT_SLUG`), and settles the **giscus data-model** (`repoId`/
`categoryId`/`mapping` become `.site-config` keys read at build).

Rejected: shipping components as permanent base assets (simpler engine, but unused files in every
site — explicitly declined); a Vite/`import.meta.env` bridge (define machinery + still needs the
import fix); scaffolder-side literal-value injection (duplicates values, messy re-runs).

## 3. Engine change: `MarkerInjector` learns a comment style

`MarkerInjector.inject` today wraps the injected block in **HTML** comment delimiters
(`<!-- anglesite:<id>:start -->`). Astro **frontmatter** (the `---` block) is TypeScript — HTML
comments are invalid there. So `MarkerInjector` gains a `CommentStyle` (`.html` for template-body
injection, `.line` for `//`-delimited frontmatter injection):

```swift
public enum CommentStyle: Sendable { case html, line }   // <!-- … -->  vs  // …
public static func inject(snippet: String, withID id: String, atAnchor anchor: String,
                          into content: String, style: CommentStyle = .html) -> Result<String, Failure>
```

`Operation.injectAtAnchor` and `PlannedStep.injectAnchor` gain a `style: CommentStyle` field; the
planner threads it through and `IntegrationScaffolder`'s inject step passes it to `MarkerInjector`.
The self-healing/idempotency logic is unchanged — only the delimiter strings vary by style.

## 4. Template changes (`Resources/Template/`)

### `scripts/config.ts` (new — base helper)

Pure KEY=value parser, ported from the plugin template. (A *script* helper, not a component — always
present, no unused-import concern.)

```ts
import { existsSync, readFileSync } from "node:fs";
import { resolve } from "node:path";

export function readConfigFromString(content: string, key: string): string | undefined {
  return content.match(new RegExp(`^${key}=(.+)$`, "m"))?.[1]?.trim();
}
export function readConfig(
  key: string,
  configPath: string = resolve(process.cwd(), ".site-config"),
): string | undefined {
  if (!existsSync(configPath)) return undefined;
  return readConfigFromString(readFileSync(configPath, "utf-8"), key);
}
```

`scaffold.sh` already lays down `scripts/` from the template, so `config.ts` ships in every new site
(verify, don't assume).

### Components — on-demand

`src/components/{BookingWidget,DonationButton,Comments}.astro` are **not** base assets. They're
copied into a site only when their integration is set up (by the scaffolder). They are props-driven
and render nothing when props are empty.

### Layouts ship with two anchors, no pre-imports

`src/layouts/BaseLayout.astro` and `src/layouts/BlogPost.astro` ship with an **import anchor** in
frontmatter and a **body anchor**, and nothing integration-specific otherwise (so an un-configured
site builds clean — no imports, no renders):

```astro
---
// anglesite:imports
---
<body>
  <slot />
  <!-- anglesite:body-end -->
</body>
```
(`BlogPost.astro` uses `<!-- anglesite:comments -->` as its body anchor.)

At setup, the scaffolder injects (each layout hosts exactly one integration in the trio):

- **frontmatter** (`// anglesite:imports`, `.line` style) — a delimited block with the component
  import **and** the `readConfig` import:
  ```ts
  // anglesite:booking:start
  import BookingWidget from "../components/BookingWidget.astro";
  import { readConfig } from "../../scripts/config";
  // anglesite:booking:end
  ```
- **body** (`<!-- anglesite:body-end -->`, `.html` style) — the config-gated render:
  ```astro
  {readConfig("BOOKING_STYLE") === "floating" && (
    <BookingWidget provider={readConfig("BOOKING_PROVIDER")} username={readConfig("BOOKING_USERNAME")}
      eventSlug={readConfig("BOOKING_EVENT_SLUG")} buttonText={readConfig("BOOKING_BUTTON_TEXT")} style="floating" />
  )}
  ```

giscus injects the analogous `Comments` import + a `{!!readConfig("GISCUS_REPO") && <Comments … />}`
render into `BlogPost.astro`. (One-integration-per-layout in the trio, so each layout's frontmatter
carries its own `readConfig` import with no cross-integration duplication; a future
two-integrations-in-one-layout case would need shared-import dedup — out of scope.)

### Pages — on-demand (`src/pages/{book,donate}.astro`)

Copied on-demand; rewritten to read via `readConfig()` instead of `import.meta.env`. Each imports
its on-demand component (copied alongside it): `book.astro` → `BookingWidget` (reads
`BOOKING_PROVIDER`/`BOOKING_USERNAME`/`BOOKING_EVENT_SLUG`, `style="inline"`); `donate.astro` →
`DonationButton` (reads `DONATIONS_LINK`→`href`, `DONATIONS_BUTTON_TEXT`→`label`,
`DONATIONS_PROVIDER`→`provider`). For v1, booking `style == "button"` is treated like `inline`
(the `/book` page) — a distinct in-page button placement is deferred.

## 5. Swift descriptor changes (`AnglesiteCore`, `IntegrationCatalog`)

- **booking:**
  - `copyFile BookingWidget.astro` (on-demand, `when: .always`).
  - `injectAtAnchor` **frontmatter** import block into `BaseLayout.astro` (`style: .line`) — `when: style == "floating"`.
  - `injectAtAnchor` **body** render block into `BaseLayout.astro` (`style: .html`) — `when: style == "floating"`.
  - `copyFile /book` page — `when: style == "inline"` (button treated as inline for v1).
  - `writeConfig`: `BOOKING_PROVIDER`, `BOOKING_USERNAME`, `BOOKING_STYLE`, **`BOOKING_EVENT_SLUG`**,
    **`BOOKING_BUTTON_TEXT`** (last two fix I4).
  - `addCSPDomains(fromProvider: true)`.
- **giscus:**
  - `copyFile Comments.astro` (on-demand).
  - `injectAtAnchor` frontmatter import block into `BlogPost.astro` (`.line`).
  - `injectAtAnchor` body render block into `BlogPost.astro` (`.html`).
  - `writeConfig`: `GISCUS_REPO`, `GISCUS_CATEGORY`, **`GISCUS_REPO_ID`**, **`GISCUS_CATEGORY_ID`**,
    **`GISCUS_MAPPING`**.
  - `addCSPDomains(fromProvider: false, extra: ["giscus.app"])`.
- **donations:**
  - `copyFile DonationButton.astro` (on-demand) + `copyFile /donate` page.
  - `writeConfig`: `DONATIONS_PROVIDER`, `DONATIONS_LINK`, `DONATIONS_BUTTON_TEXT`.
  - `addCSPDomains(fromProvider: true)`.

The booking/giscus `style: .line` frontmatter import op is the new capability; everything else uses
existing op kinds. The planner already resolves `injectAtAnchor`; it now also carries `style`.

## 6. Error handling

`readConfig` returns `undefined` for a missing key/file → components receive `undefined` props and
render nothing; layout conditionals are false. A site that has **not** set up an integration has no
injected import/render blocks at all, so it builds clean under `noUnusedLocals`. Injection is
idempotent (delimited blocks, self-healing) — re-running setup replaces the block, not duplicates.

## 7. Testing

**Swift (`AnglesiteCoreTests`, Swift Testing):**
- `MarkerInjectorTests`: add `.line` (JS-comment) cases — insert, idempotent replace, orphan-heal,
  anchor-not-found — paralleling the existing `.html` cases.
- `IntegrationCatalogTests`: assert the new config keys (`BOOKING_EVENT_SLUG`, `BOOKING_BUTTON_TEXT`,
  `GISCUS_REPO_ID`, `GISCUS_CATEGORY_ID`, `GISCUS_MAPPING`); update
  `injectedSnippetsCarryNoClientDirective` to cover both the frontmatter and body inject ops.
- `IntegrationPlannerTests`: floating-booking and giscus plans now contain **two** `injectAnchor`
  steps (frontmatter `.line` + body `.html`) with the right snippets; assert the new keys appear in
  `upsertConfig`; assert the frontmatter step's snippet contains the component + `readConfig` imports.
- `IntegrationScaffolderTests`: a `.line`-style inject into a fixture frontmatter applies idempotently.

**Template (`IntegrationTemplateAssetsTests`, classic URL APIs only — see the
`libswift_DarwinFoundation3` CI note):**
- assert `scripts/config.ts` exists;
- assert `BaseLayout.astro` / `BlogPost.astro` ship the `// anglesite:imports` anchor + their body
  anchor, and do **not** statically import the integration components (they're injected/on-demand);
- assert `book.astro` / `donate.astro` reference `readConfig` and not `import.meta.env`;
- update the `pageEnvKeysAreWrittenByDescriptors` guard to extract `readConfig("KEY")` calls and
  assert ⊆ descriptor-written keys.

**Build smoke (the real proof) — explicitly scoped:** CI's JS lane builds the edit-overlay, not the
Astro template, so a full `astro build` of a scaffolded+configured site is **not** added here. The
Swift + asset tests verify the wiring statically. A one-off manual `npm run build` of a
booking/donations/giscus-configured scaffold is the acceptance check, noted in the PR. A
template-build CI lane is a separate follow-up.

## 8. Out of scope (tracked separately)

- Wiring `BlogPost.astro` to an actual blog collection/route (giscus has no host page until the
  template gains a blog system).
- A distinct in-page booking **button** placement (`style == "button"` treated as inline for v1).
- CSP → `public/_headers` enforcement (descriptors write `SCRIPT_ALLOW` into `.site-config`;
  generating `_headers` / the native pre-deploy gate is a separate slice).
- A two-integrations-in-one-layout shared-`readConfig`-import case (trio is one-per-layout).
