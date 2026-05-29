# New Site Onboarding — Design

**Status:** Approved (brainstorm) — ready for implementation planning
**Date:** 2026-05-29
**Repo:** `Anglesite/Anglesite-app`
**Related:** `docs/build-plan.md` Phase 9.1 ("New Site… button in the launcher" follow-up), primed npm cache (#6), MAS security-scoped grant (Phase 10.1 Task 7)

## Problem

A non-technical owner who downloads the app cannot create a site. The "New Site…" affordance in `SitesLauncherView` is a disabled placeholder that tells the owner to run `/anglesite:start` in Claude Code — which requires a terminal and a Claude install, neither of which the target audience has. The cold-start path (download → create a site → see it live) is the single biggest gap to a 1.0 aimed at non-technical users.

## Goal

Clicking **New Site** opens a short native wizard. The owner answers four steps and lands in a live preview of *their own* site — no terminal, no Claude process, working identically in the Developer-ID and Mac App Store builds.

Success criterion: a first-time owner with no developer tools installed creates a themed, content-seeded site and watches it render, entirely inside the app.

## Non-goals

- **Replacing the chat `start` skill.** The conversational interview remains the richer path for owners who have Claude and want design iteration, tool install, GitHub backup, etc. This wizard is the deterministic floor, not a superset.
- **The freedesignmd 121-theme catalog.** That path needs web fetch + token translation (effectively Claude/network work). The wizard ships the 9 built-in themes only; "more looks" stays a chat enhancement.
- **GitHub backup / Cloudflare / tool install during onboarding.** Those are separate flows (some already exist). The wizard's job ends at "site is open and previewing."
- **Custom domain, deploy, analytics.** Out of scope; tracked elsewhere.

## Key decisions

1. **Native wizard, no Claude.** Scaffolding is fully deterministic. This is what makes it work in MAS (where chat is compiled out) and on machines without Claude installed.
2. **Scope = type + details + theme + first content.** The first preview shows the owner's words and chosen look, not lorem ipsum / "type /start in Claude".
3. **Theme & content application logic lives app-side in Swift**, but reads theme *data* from the bundled plugin at runtime (see Drift guard). The plugin remains the data source of truth; only the application algorithm is in the app. This avoids a paired plugin PR + release as a prerequisite to shipping.
4. **No auto-delete on partial failure.** The filesystem is the source of truth; a half-made site directory is left on disk for retry or manual cleanup.

## Components

Each unit has one job, a defined interface, and is testable in isolation.

### `NewSiteWizard` (SwiftUI, `AnglesiteApp`)
The presentation layer. A step enum drives a sequence:

```
.type → .details → .look → .content → .building
```

Owns a `NewSiteDraft` value and nothing else. Back/Continue navigation; Continue is disabled until the current step validates. Knows nothing about scaffolding mechanics — on the `.building` step it subscribes to a `SiteScaffolder` stream and renders progress.

```swift
struct NewSiteDraft {
    var siteType: SiteType          // business | personal | blog | portfolio | organization
    var name: String                // "Blue Bottle Cafe"
    var tagline: String             // optional
    var themeID: String             // resolved default from siteType, owner-overridable
    var headline: String            // homepage <h1>; defaults from name
    var blurb: String               // homepage intro <p>; optional
}
```

### `SiteScaffolder` (actor, `AnglesiteCore`)
The engine. Validates a `NewSiteDraft`, runs the pipeline, emits progress:

```swift
enum ScaffoldStep: Sendable, Equatable {
    case creatingFolder, copyingTemplate, applyingTheme,
         writingContent, installing, registering
    case done(siteID: String)
    case warning(step: String, message: String)   // non-fatal
    case failed(step: String, message: String)     // fatal, with retry
}

actor SiteScaffolder {
    func scaffold(_ draft: NewSiteDraft) -> AsyncStream<ScaffoldStep>
}
```

Pure orchestration. Every subprocess (`scaffold.sh`, `npm install`) goes through `ProcessSupervisor.shared`; output streams to `LogCenter` under a `scaffold:<slug>` source so the debug pane sees it.

### `ThemeCatalog` (`AnglesiteCore`)
Parses the 9 built-in themes out of the bundled `template/scripts/themes.ts` (resolved via `PluginRuntime`). The file exports `THEMES: Record<string, Theme>`, each `{ displayName, description, bestFor: string[], vars: Record<string,string> }`. Returns `[Theme]`:

```swift
struct Theme: Sendable, Identifiable {
    let id: String          // "warm"  (the THEMES record key)
    let name: String        // "Warm"  (displayName)
    let blurb: String       // description
    let swatch: [String]    // derived from vars["color-primary"] / ["color-accent"] for the gallery
    let cssVars: [String: String]  // = vars: custom-property name → value
}
```

Does not execute TypeScript — `THEMES` is a flat data declaration, parsed with a tolerant scan. One source of theme data, consumed by both the gallery UI and `ThemeApplier`.

**Default theme suggestion** is an app-side `SiteType → themeID` table (5 entries — e.g. `business → classic`, `personal → elegant`, `blog → warm`, `portfolio → studio`, `organization → community`). The wizard collects only the 5 broad site types, so it does not consult the plugin's fine-grained `bestFor` arrays (those map specific business types like `legal`/`restaurant` and stay with the chat path). The owner can override the suggestion in the gallery.

### `ThemeApplier` (`AnglesiteCore`)
Given a `Theme` and a site directory, rewrites the `:root { … }` block in `src/styles/global.css`: replaces color + font custom properties, leaves spacing / radius / shadow / other properties untouched. Pure string transform over a known file. Mirrors exactly what the plugin's `themes` skill Step 3 does by hand.

### `HomepageWriter` (`AnglesiteCore`)
Given headline + blurb, rewrites three known strings in the freshly-scaffolded `src/pages/index.astro`: the `BaseLayout` `title=`, `description=`, and the `<h1>` + intro `<p>`. Operates on known template content (safe targeted replace, not a fuzzy patch). Empty inputs leave template defaults. Owner text is escaped for the Astro attribute / markup context.

### Launcher integration (`SitesLauncherView`)
The disabled "New Site…" label becomes a live button presenting `NewSiteWizard` as a sheet. On `.done(siteID)` the launcher reuses its existing `open(siteID:)` path. In MAS it mints the per-site security-scoped bookmark before opening — the same code path as today's `openFolder()`.

## Data flow / pipeline

```
derive slug from name → collision check against ~/Sites and SiteStore
~/Sites/<slug>/
  → scaffold.sh --yes <dir>          (ProcessSupervisor; bundled zsh + plugin template)
  → append to .site-config           (SITE_NAME, SITE_TYPE, tagline — merge, do NOT clobber)
  → ThemeApplier.apply(theme, dir)   (global.css :root)
  → HomepageWriter.write(headline, blurb, dir)  (index.astro)
  → npm install --prefer-offline --cache <primed cache #6>   (long pole)
  → SiteStore.add(url)  [+ SecurityScopedBookmark in MAS]
  → openWindow(siteID)  → PreviewSession starts the dev server → live preview
```

Everything before `npm install` is fast and local. `npm install` is the long pole, mitigated by the primed npm cache (#6); the wizard's `.building` screen shows an indeterminate "Installing…" with the streamed log available.

Note: `scaffold.sh` excludes `.site-config` from its rsync copy and itself stamps `ANGLESITE_VERSION` into a fresh `.site-config`. The wizard's write step therefore **appends/merges** `SITE_NAME` / `SITE_TYPE` / `tagline` into that file rather than overwriting it, preserving the stamped version line.

## Theme data drift guard

The cost of applying themes app-side is that the app depends on the shape of `template/scripts/themes.ts`. A CI/unit test (`ThemeCatalogTests`) parses the **current bundled** `themes.ts` and asserts:

1. Exactly 9 themes parse from `THEMES`.
2. Each theme has the expected keys (`displayName`, `description`, `vars` including `color-primary`, `color-accent`, `font-heading`, `font-body`).
3. The app-side `SiteType → themeID` default table resolves to a real parsed theme id for every `SiteType` case.

If the plugin restructures `themes.ts`, this test fails loudly in CI rather than the wizard silently shipping an empty/broken gallery. This keeps `themes.ts` authoritative: the app reads its data, never forks a copy of the values into Swift.

## Error handling

Each step maps failure to `ScaffoldStep.failed(step, message)` (plain language, with the raw stderr behind a disclosure) or `.warning(...)`:

| Failure | Behavior |
|---|---|
| Slug/folder collision | Caught **before** scaffolding — live "that name is taken" hint on the Details step; Continue disabled. |
| `scaffold.sh` non-zero exit | Fatal. "Couldn't create the site files." + stderr disclosure. Retry/Cancel. |
| Theme apply fails | **Non-fatal warning.** Log + toast; a themeless-but-working site beats a hard stop. |
| Homepage write fails | **Non-fatal warning.** Same as above. |
| `npm install` fails (offline / no cache) | Site is **already scaffolded + registered**, so still `openWindow`. Preview shows the existing `PreviewSession` "dependencies not installed — run npm install" state. Owner's work is not lost. |

**Rollback policy:** no auto-delete. A partial `~/Sites/<slug>/` stays on disk. `scaffold.sh` is rerun-safe (`--ignore-existing`), so a retry into the same folder is safe; otherwise the owner trashes it in Finder.

## MAS vs DevID

The pipeline is identical in both targets — the payoff of the no-Claude decision. The only difference is folder-access provenance:

- **DevID (sandbox off):** create `~/Sites/<slug>/` directly.
- **MAS (sandboxed):** create inside a directory the app already holds a security-scoped grant for; if none, prompt once for `~/Sites` access via `NSOpenPanel`, then mint and persist the per-site `SecurityScopedBookmark` before `openWindow` — identical to the current `openFolder()` path.

No chat dependency in either build.

## Testing

- **`ThemeCatalogTests`** — parse the real bundled `themes.ts` (the drift guard) plus a checked-in fixture; assert 9 themes, key presence, full business-type coverage.
- **`ThemeApplierTests`** — apply each theme to a `global.css` fixture; assert color/font vars change, spacing/radius/shadow survive, and the transform is idempotent.
- **`HomepageWriterTests`** — write into an `index.astro` fixture; assert the three target strings change, surrounding markup survives, empty inputs are no-ops, and owner text is correctly escaped.
- **`SiteScaffolderTests`** — inject a fake launcher (same pattern as `ClaudeAgent` / `GitHubAuthFlow` tests) + a tmp directory; drive the full stream and assert step order, the warning paths (theme/content non-fatal), and the `npm install`-fails-but-still-registers-and-emits-`done` path (the launcher owns `openWindow`).
- **Slug derivation / collision** — plain unit over `NewSiteDraft.name → slug`; the view stays thin.

## Open follow-ups (out of scope here)

- freedesignmd catalog as an in-wizard "more looks" path (needs network + translation).
- Pre-filling more than the homepage (about page, business hours) — could read from `.site-config` later.
- Offering the optional Claude design-refinement handoff after open, in the DevID build only.
