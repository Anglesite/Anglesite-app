# Dependency Sync — auto-update stale site dependencies on open

**Date:** 2026-07-06
**Status:** Approved design, pre-implementation
**Related:** #501 (scaffold.sh heredoc bug), #502 (container preview timeout — the motivating incident)

## 1. Summary

When a `.anglesite` site's `Source/package.json` has drifted behind the app's bundled
template (e.g. an old `astro` version range), the app detects this on site open and
offers to bring the site's dependency ranges up to date — before the drift causes a
slow, silent `npm install` inside the sandboxed container at preview-boot time (the
root cause identified while investigating #502).

**Framing:** the app has not shipped 1.0 yet, so there is no real population of
customer sites with organically-drifted dependencies. This is **preventative
infrastructure** — the goal is to have the right mechanism (baseline provenance,
3-way comparison, safe update path) fully in place *before* real customers start
customizing sites, so the ambiguous "did the user mean to pin this?" case never has
to be guessed at in production. The only sites that exist today with drift are the
team's own internal dev/test sites (e.g. the one that caused #502) — fixing those is
a useful side effect, not the primary goal.

## 2. Scope

- Compares **only** dependency version ranges for package names present in **both**
  the site's `package.json` and the template's current `package.json`. Never adds a
  package the site doesn't have; never removes one it does have — even if the
  template gained or dropped something. Smallest safe surface: version-range
  reconciliation, not a general package-set sync.
- Out of scope: `package.json` `scripts`, `astro.config.ts`/`tsconfig.json` content,
  any file other than `package.json` + `package-lock.json`.

## 3. Provenance — distinguishing "template moved" from "user customized"

A site's dependency entries can differ from the current template for two reasons:
the template evolved since the site was created, or the user deliberately changed
something. Only the first case should ever be auto-offered.

**`Config/dependency-baseline.json`** (app-owned, never in git, alongside
`settings.plist`): a flat `[String: String]` map of package name → version range,
captured from the template's `package.json` (`dependencies` + `devDependencies`) at
the moment a site is scaffolded. `SiteScaffolder` writes this immediately after
copying the template (new sites only).

**Three-way decision**, per package name present in both site and template:

| site range == baseline range? | baseline == template (current)? | Result |
|---|---|---|
| yes | yes | nothing to do |
| yes | no | **offer to bump** — site never touched it, template moved forward |
| no | — | leave alone — user's intentional edit wins, never prompted |

**Legacy sites** (no `dependency-baseline.json` — any site opened before this
feature exists): skip the middle column. Compare the site's current range directly
against the template's current range for every shared package name; a template
range that's newer is offer-worthy, full stop. Whatever the user decides (update or
skip), write `dependency-baseline.json` at that point using the site's resulting
versions, so every later open gets the real 3-way treatment. This path exists to
handle the team's own pre-existing test sites sanely, not as a customer migration
guarantee (see §1).

**Version-ordering comparator** (new, small, `AnglesiteCore`): parses a range
string's leading `major.minor.patch` (stripping `^`/`~`/etc. prefix characters) and
compares numerically. This is ordering only — not full semver-range set logic (no
need to reason about what a range *matches*, only whether the template's stated
range is newer than the site's or baseline's). Malformed or non-numeric leading
segments (e.g. a stray pre-release tag) are treated as equal/incomparable and
skipped rather than guessed at.

## 4. Detection hook

In `SiteWindowModel.loadAndStart()` (`Sources/AnglesiteApp/SiteWindowModel.swift`),
immediately after `site` resolves and before `preview.open()` is called. The check
reads and parses two small local JSON files (site's `package.json`,
`dependency-baseline.json` if present) plus the app-bundled template's
`package.json` — no container, no network, effectively instant. It completes before
`preview.open()` would otherwise be called.

If the diff produces zero offers, nothing changes — `preview.open()` proceeds
exactly as today.

## 5. Prompt UX

If there's anything to offer: a `.sheet` on `SiteWindow`, matching the app's
existing sheet-driven-by-an-optional-model property pattern (see the Siri-readiness
sheet). Content: one row per offered package, `name: currentRange → offeredRange`.

Two actions, all-or-nothing (no per-row accept/reject in v1 — YAGNI until a real
case needs it):
- **Update** — apply every offered bump together (see §6), then proceed into
  `preview.open()`.
- **Skip** — no file changes, proceed into `preview.open()` immediately. Not
  remembered as dismissed: if the drift is still there next time the site opens, it
  prompts again. No persisted "don't ask again" — smallest state footprint for v1,
  consistent with the preventative/no-installed-base framing in §1.

## 6. Execution — applying an accepted update

No host-side npm invocation (there is no host Node — #70). On **Update**:

1. Rewrite `Source/package.json`: for each accepted package name, replace its
   version range with the template's current range. Every other line of the file —
   including any package the user added or customized — is untouched.
2. Delete `Source/package-lock.json`.
3. Overwrite `Config/dependency-baseline.json` with the post-update ranges (these
   are now the new "site never touched it" baseline going forward).
4. Proceed into `preview.open()` as normal.

Step 2 means the next container boot's existing `container/hydrate.sh` no longer
finds a lockfile to `cmp` against the baked one, so it falls to its own `npm install`
branch — already-proven, already-tested machinery, completely unchanged by this
feature. This is a deliberate reuse: the alternative (a new dedicated
"update-and-install-now" container-exec path with its own progress state machine)
was considered and rejected as unnecessary scope for what §1 frames as a small,
preventative feature.

**Framing the resulting slow boot**: since this feature is the reason the lockfile
is gone, the app knows this boot will hit the slow, real `npm install` path instead
of the instant hardlink path. `PreviewModel`/the loading view threads a transient
flag through so that one boot's progress text reads "Updating dependencies — this
may take a minute" instead of the generic "Starting dev server…" — directly
addressing the UX gap that made the original #502 slowdown look like a silent hang.

## 7. Error handling

- Site's `package.json` missing or fails to parse as JSON → skip the check silently
  (log at debug level), proceed to `preview.open()` unmodified. This is a diagnostic
  convenience feature; it must never block a site from opening.
- Writing the updated `package.json`/baseline fails (disk/permission error) → surface
  a lightweight non-blocking error, then still proceed to `preview.open()` with
  whatever's on disk (don't strand the window mid-decision).

## 8. Testing

All comparison/diff logic is pure Swift over in-memory or fixture JSON — no
container, no npm, no network:

- Version-ordering comparator: unit tests over range-string pairs, including
  malformed/non-numeric edge cases.
- Three-way diff function (`site map, baseline map?, template map → [offer]`):
  fixture-based unit tests covering all four table rows in §3 plus the
  no-baseline fallback path.
- `dependency-baseline.json` Codable round-trip.
- `package.json` rewrite step: given input text + an accepted-offers list, assert
  the exact output text — tested independently of any live container.
- `SiteScaffolder`: extend its existing test suite to assert the baseline file is
  written for a newly-scaffolded site.
- The actual `npm install` outcome after a lockfile deletion is **not** new test
  surface for this feature — it's exercised by `hydrate.sh`'s existing coverage.

## 9. Files touched (indicative — implementation plan will pin exact paths)

- New: dependency-baseline model + version comparator + 3-way diff (`AnglesiteCore`)
- New: `package.json` rewrite helper (`AnglesiteCore`)
- Modify: `SiteScaffolder.swift` — write baseline at scaffold time
- Modify: `SiteWindowModel.swift` — detection hook before `preview.open()`
- Modify: `SiteWindow.swift` — the update-offer sheet
- Modify: `PreviewModel.swift` / preview loading view — "Updating dependencies…"
  transient framing for the post-update boot
