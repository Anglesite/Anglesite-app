# Bucket 3 — Template Config Wiring (Design)

**Date:** 2026-06-21
**Status:** Design / approved — no implementation yet
**Issue:** #282 (follow-up to the Bucket 3 integration wizard framework, PR #283)
**Branch:** `feat/282-template-wiring`

## 1. Problem

The Bucket 3 framework (shipped on `main`) writes a site's integration config into `.site-config`
and copies/injects Astro components, but the **app-owned website template doesn't consume any of
it**. Concretely (verified on `main`):

- `Resources/Template/` has **no config bridge** — no `config.ts`, no `csp.ts`. `astro.config.mjs`
  is `defineConfig({})` and `scaffold.sh` only writes `ANGLESITE_VERSION` to `.site-config`.
- The scaffolded pages (`book.astro`, `donate.astro`) read `import.meta.env.BOOKING_*` /
  `DONATIONS_*`, which nothing populates — so they render no data.
- The floating-booking and giscus integrations use `injectAtAnchor` to drop `<BookingWidget>` /
  `<Comments>` into layouts, but never add the component `import` to the layout frontmatter — an
  Astro build error (C1).
- Inline booking drops the user's `eventSlug` (I4).

So a GUI/Siri/chat-driven setup writes correct config that produces a site that either renders
nothing or fails to build. This spec makes the template **consume** the config the framework writes.

## 2. Approach (locked)

**`readConfig()` in Astro frontmatter + config-driven conditional render.** A small build-time
`readConfig(key)` helper reads the flat `.site-config`; pages and layouts read the keys they need
in frontmatter and conditionally render the integration component. The Swift scaffolder's job
simplifies to **writing `.site-config`** (plus copying on-demand pages) — no more snippet injection
for the trio.

Rejected alternatives: a Vite/`import.meta.env` bridge in `astro.config.mjs` (adds define
machinery and still needs a separate fix for injected-component imports); scaffolder-side literal
value injection (duplicates values between files and `.site-config`, messy re-runs).

### Structural consequence: components ship in the base template

A layout that conditionally renders `<BookingWidget>` must `import` it, and `tsconfig` extends
`astro/tsconfigs/strict` (`noUnusedLocals`), so the imported component must always exist. Therefore
the three components (`BookingWidget`, `DonationButton`, `Comments`) are **permanent base-template
assets** — present in every scaffolded site, rendering *nothing* unless their config is set (zero
output cost when unused). Consequences:

- **Layouts** (`BaseLayout`, `BlogPost`) ship pre-wired: import the component + conditionally render
  it from `.site-config`.
- **Pages** (`/book`, `/donate`) remain **copied on-demand** by the scaffolder — standalone routes a
  site only gets when it set up that integration.
- **Integration setup (Swift)** = write `.site-config` keys (+ copy the on-demand page).
- `Operation.injectAtAnchor`, `MarkerInjector`, and the scaffolder's `injectAnchor` step **stay** in
  the codebase (tested, available for future integrations) — the trio simply no longer uses them.

This resolves **C1** (no orphan imports — components always present), **I3** (a real build-time
bridge), **I4** (`BOOKING_EVENT_SLUG`), and the **giscus data-model** decision (`repoId`/`categoryId`/
`mapping` become `.site-config` keys read at build).

## 3. Template changes (`Resources/Template/`)

### `scripts/config.ts` (new)

Pure KEY=value parser, ported from the plugin template:

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

### Components (permanent base assets)

`src/components/{BookingWidget,DonationButton,Comments}.astro` already exist in the template (added
in the Bucket 3 work). They become permanent base assets — `scaffold.sh` already lays down `src/`
from the template, so they ship in every new site. No change beyond confirming they're props-driven
and render nothing when their props are empty/undefined.

### `src/layouts/BaseLayout.astro` (floating booking)

Frontmatter imports `BookingWidget` + `readConfig`, reads booking config, conditionally renders the
floating widget. The existing `<!-- anglesite:body-end -->` anchor stays as a harmless marker
(injection no longer used).

```astro
---
import BookingWidget from "../components/BookingWidget.astro";
import { readConfig } from "../../scripts/config";
const bookingFloating = readConfig("BOOKING_STYLE") === "floating";
---
  <slot />
  {bookingFloating && (
    <BookingWidget
      provider={readConfig("BOOKING_PROVIDER")}
      username={readConfig("BOOKING_USERNAME")}
      eventSlug={readConfig("BOOKING_EVENT_SLUG")}
      buttonText={readConfig("BOOKING_BUTTON_TEXT")}
      style="floating"
    />
  )}
  <!-- anglesite:body-end -->
</body>
```

(The exact relative import path from `src/layouts/` to `scripts/config.ts` is verified during
implementation; `scaffold.sh` must ensure `scripts/config.ts` lands in the scaffolded site.)

### `src/layouts/BlogPost.astro` (giscus)

Imports `Comments` + `readConfig`, renders when `GISCUS_REPO` is set:

```astro
---
import Comments from "../components/Comments.astro";
import { readConfig } from "../../scripts/config";
const showComments = !!readConfig("GISCUS_REPO");
---
  <slot />
  {showComments && (
    <Comments
      repo={readConfig("GISCUS_REPO")}
      repoId={readConfig("GISCUS_REPO_ID")}
      category={readConfig("GISCUS_CATEGORY")}
      categoryId={readConfig("GISCUS_CATEGORY_ID")}
      mapping={readConfig("GISCUS_MAPPING")}
    />
  )}
  <!-- anglesite:comments -->
```

### `src/pages/{book,donate}.astro` (copied on-demand)

Rewrite to read via `readConfig()` instead of `import.meta.env`. `book.astro` reads
`BOOKING_PROVIDER`/`BOOKING_USERNAME`/`BOOKING_EVENT_SLUG` (style fixed `inline`); `donate.astro`
reads `DONATIONS_LINK`/`DONATIONS_BUTTON_TEXT`/`DONATIONS_PROVIDER` (match `DonationButton`'s prop
names `href`/`label`/`provider`).

### `scripts/scaffold.sh`

Confirm the scaffold lays down `scripts/config.ts` and the three components into the new site (they
live under the template `src/`/`scripts/`, which `scaffold.sh` already copies — verify, don't assume).

## 4. Swift changes (`AnglesiteCore`)

Descriptor-data only; the planner and scaffolder engines are unchanged (they already handle
`copyFile`/`writeConfig`/`addCSPDomains`; we remove `injectAtAnchor` steps from the trio's plans).

In `IntegrationCatalog`:

- **booking:** add `BOOKING_EVENT_SLUG = {{eventSlug}}` and `BOOKING_BUTTON_TEXT = {{buttonText}}` to
  `writeConfig` (fixes I4). Remove the `injectAtAnchor BaseLayout` op and the
  `copyFile BookingWidget.astro` op (base asset). Keep `copyFile /book` gated on
  `style == "inline"`, `BOOKING_PROVIDER/USERNAME/STYLE`, and provider CSP.
- **giscus:** add `GISCUS_REPO_ID = {{repoId}}`, `GISCUS_CATEGORY_ID = {{categoryId}}`,
  `GISCUS_MAPPING = {{mapping}}` to `writeConfig`. Remove the `injectAtAnchor BlogPost` op and the
  `copyFile Comments.astro` op. Keep `giscus.app` CSP.
- **donations:** remove the `copyFile DonationButton.astro` op (base asset). Keep `copyFile /donate`,
  `DONATIONS_*` config, and provider CSP.

Net: the trio's descriptors become `writeConfig` + `addCSPDomains` (+ on-demand page `copyFile`)
only. `Operation.injectAtAnchor` / `MarkerInjector` / the scaffolder's `injectAnchor` step are
retained but unused by the trio.

## 5. Error handling

`readConfig` returns `undefined` for a missing key or absent file. Components receive `undefined`
props and render nothing/an empty state, and the layout conditionals are false — so a site that has
**not** set up an integration still builds cleanly (no orphan imports, no missing data crash). This
is the `noUnusedLocals`-safe path: the imported component is always referenced inside the
conditional.

## 6. Testing

**Swift (`AnglesiteCoreTests`, Swift Testing):**
- `IntegrationCatalogTests`: assert the new keys are present (`BOOKING_EVENT_SLUG`,
  `BOOKING_BUTTON_TEXT`, `GISCUS_REPO_ID`, `GISCUS_CATEGORY_ID`, `GISCUS_MAPPING`); repoint or remove
  `injectedSnippetsCarryNoClientDirective` (no trio `injectAtAnchor` snippets remain).
- `IntegrationPlannerTests`: floating-booking and giscus plans no longer contain an `injectAnchor`
  step — assert `writeConfig`/`addCSP` only; assert `BOOKING_EVENT_SLUG` and the giscus IDs appear in
  the resolved `upsertConfig`.
- `IntegrationScaffolderTests` / `IntegrationOperationsTests`: drop assertions that depended on
  layout injection for the trio.

**Template (`IntegrationTemplateAssetsTests`, classic URL APIs only — see the
`libswift_DarwinFoundation3` CI note):**
- assert `scripts/config.ts` exists;
- assert `BaseLayout.astro` / `BlogPost.astro` / `book.astro` / `donate.astro` reference `readConfig`
  and do **not** reference `import.meta.env`;
- update the `pageEnvKeysAreWrittenByDescriptors` guard to extract `readConfig("KEY")` calls (instead
  of `import.meta.env.KEY`) and assert they are a subset of the keys the matching descriptor writes.

**Build smoke (the real proof) — explicitly scoped:** CI's JS lane builds the edit-overlay, not the
Astro template, so a full `astro build` of a scaffolded site is **not** added here. The Swift +
asset tests verify the wiring statically (files exist, reference `readConfig`, keys line up). A
one-off manual `npm run build` of a booking/donations/giscus-configured scaffold is the acceptance
check, noted in the PR. Adding a template-build CI lane is a separate follow-up, not part of this
slice.

## 7. Out of scope (tracked separately)

- Wiring `BlogPost.astro` to an actual blog collection/route — giscus has no host page until the
  template gains a blog system. The layout exists and conditionally renders; routing real posts
  through it is a separate template feature.
- CSP → `public/_headers` enforcement (the descriptors write `SCRIPT_ALLOW` into `.site-config`;
  generating `_headers` from it / the §7 native pre-deploy gate is a separate slice).
- The `githubSponsors` → `github-sponsors` provider-id casing is already fixed on `main`.
