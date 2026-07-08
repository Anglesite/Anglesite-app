# Project Impact Analysis (#309) — design

## Problem

Changing a shared Astro component or layout can affect dozens of pages, and users discover the
blast radius only after previewing or deploying. The app already maintains a project dependency
graph (`SiteGraphExplorer`); #309 asks it to *predict* the impact of an edit before it happens:
"Used by 27 pages", "Imported by 4 layouts", "References 12 images", "Included in 3 content
collections".

## Approach — v1, fully deterministic

Reuse the existing graph rather than building a second scanner (contrast: PR #535's
`DeadAssetScanner` needed its own scan because dead-asset detection has a different safety
posture — "never over-flag unused" — and needed alias-resolution machinery the explorer graph
doesn't have; impact analysis only needs *reachability* over the graph that already ships).

### Core: `ImpactAnalysis` (AnglesiteCore)

Pure function over a `SiteGraphExplorerSnapshot`:

- `analyze(snapshot:targetID:) -> Report?` — BFS over the **reverse** of the dependency edges
  (`imports`, `usesLayout`, `referencesAsset`; each means "source depends on target"), collecting
  the transitive set of nodes that would change if the target is edited. Cycle-safe via a visited
  set; `nil` for an unknown target.
- `contains` edges (collection → entry) are membership, not dependency: they never propagate
  impact, and only map affected entries back to `affectedCollections`.
- Grouped, title-sorted output: `affectedPages`, `affectedEntries`, `affectedCollections`,
  `dependentLayouts`, `dependentComponents`, `dependentStyles`, plus the one forward-looking
  group `referencedAssets` (the target's own direct asset references).
- Inherits the graph's under-reporting bias: an unresolvable reference never becomes an edge, so
  the analysis may miss an affected page but never invents one.

### Graph fix: frontmatter `layout:` edges

`SiteGraphExplorer.build` only extracted import statements and asset references, so a markdown
page using `layout: ../layouts/Base.astro` had **no** edge to its layout — editing a layout would
under-report exactly the headline case the issue opens with. Markdown-ish files (`.md`, `.mdx`,
`.mdoc`, `.markdown`) now also get a `usesLayout` edge from their frontmatter `layout` field
(via the existing `Frontmatter.parse` + `resolveImport`). `.astro` files are excluded — their
frontmatter is JS, not YAML.

### UI: "Impact" section in the Site Graph inspector

The Site Graph pane is already the app's "select a component" surface, refreshed live from
`SiteContentGraph`'s change stream. Selecting any node now shows an Impact section between the
node header and the existing Depends On / Referenced By edge lists:

- A one-line summary — "Editing this would affect N pages." — the issue's headline number
  (pages + entries), or an explicit "nothing else depends on it" when the blast radius is zero.
- One clickable list per non-empty group (affected pages with their routes, entries,
  collections, layouts, components, styles, referenced assets); clicking navigates the selection
  so the blast radius can be walked in place.

Computed as a `SiteGraphExplorerModel.selectedImpact` property over the **full** snapshot (not
the kind-filtered view — impact is factual and must not shrink because a node kind is toggled
off in the toolbar), matching the model's existing recompute-on-read style.

## Non-goals (follow-ups, not this slice)

- AI-edit integration ("this AI edit will affect 18 pages" before apply) — belongs to the
  #459-era edit pipeline, not the Claude-plugin path.
- Preview of affected routes, deployment-scope estimation, dependency diffing (new/removed
  edges) — the issue's nice-to-haves.
- Impact badges outside the graph pane (editor toolbar, navigator rows).

## Testing

`ImpactAnalysisTests` (Swift Testing, pure snapshots — no filesystem): transitive closure through
layouts, direct + indirect dependents, forward asset references, collection membership,
contains-is-not-dependency, cycle termination, style dependents, deterministic ordering,
self-exclusion, unknown target. `SiteGraphExplorerTests` gains a frontmatter-layout edge case
over a real temp-dir site.
