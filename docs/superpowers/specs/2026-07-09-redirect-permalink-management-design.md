# Redirect/Permalink Management: Never Break an Inbound URL

Design for [#530](https://github.com/Anglesite/Anglesite-app/issues/530).

## Motivation

Long-running personal sites treat permalinks as sacred — a 25-year blog has inbound
links from every era, and "cool URIs don't change." Nothing in the app owns redirects
today: removing a page silently breaks every inbound URL, and the pre-deploy gate
doesn't notice.

## Scope revision

The original issue proposed three break-detection triggers: navigator rename,
front-matter route edits, and page deletion (#516). Investigation during design found:

- The navigator's existing "Rename" (`NavigatorRenameService`) only rewrites a page's
  front-matter *title* — it reuses the existing `route` unchanged. Routes are derived
  100% from the content filename (Astro content-collection `id` from the glob loader),
  and no front-matter `slug`/`permalink` field exists in any collection schema.
  **There is no UI action anywhere today that changes a published route.**
- #516 (delete/duplicate page) is open and unbuilt — only "Rename" exists in the
  navigator context menu.

Given this, the design drops the rename-hook trigger entirely (nothing to hook into)
and adds a **minimal delete action** as part of this work — real content deletion
genuinely does remove a route, unlike title-rename, and #516 can build on the same
offer path later rather than duplicating it. The **pre-deploy diff scan** becomes the
primary safety net, since it catches route changes regardless of cause (in-app or an
external edit via the `Source/` git repo — see CLAUDE.md's "git is the source of
truth").

## 1. Redirect data model & store

A new `RedirectsStore` in `AnglesiteCore`, backed by `Source/redirects.json` — a plain
JSON array, git-tracked like `.site-config`, so it travels with the repo:

```json
[{ "source": "/old-path", "destination": "/new-path", "code": 301 }]
```

- `code` is `301` or `302` (enum), defaulting to `301` — permanent by default, matching
  "cool URIs don't change."
- Validation on write:
  - `source` must start with `/`.
  - No duplicate `source` entries.
  - No direct cycles (`source == destination`, or an existing `B → A` when adding
    `A → B`).
  - No deep chain-resolution (`A → B → C`) — out of scope, matching Cloudflare's own
    behavior of following each hop independently.

## 2. Template wiring (Astro + Cloudflare)

`Resources/Template/` has no Cloudflare adapter — it's a static build, and Astro's own
`redirects` config only emits HTML meta-refresh redirects for static output, not real
HTTP 301s. So `redirects.json` needs two consumers, both driven by a small Astro
integration hook added to the template:

- **Dev preview**: an `astro:config:setup` hook reads `redirects.json` and calls
  `updateConfig({ redirects })`, so redirects work live in the in-app preview.
- **Production**: an `astro:build:done` hook writes `dist/_redirects` in Cloudflare
  Pages' plain-text format (`/source /destination 301`), so the real deploy gets real
  edge-level redirects regardless of the static-output limitation.

`redirects.json` is the single source of truth; both outputs are generated at build
time and never hand-edited.

## 3. Manual editor UI

A new **"Redirects" tab** in Site Settings (`PlistEditorView`, alongside the existing
Website/Analytics tabs) — a table of source/destination/code rows with add/edit/delete,
following the same dirty-tracking and save pattern as the Analytics tab
(`isAnalyticsDirty` → `saveAnalytics()`).

## 4. Delete action + break-detection offer

There is no delete action in the navigator today. This design adds a **minimal
delete**: remove the file and git-commit, mirroring `NavigatorRenameService`'s
save-then-best-effort-commit pattern. If the deleted page had a route, show a
confirmation dialog first:

> "Deleting this page removes `/some-route`. Create a redirect so old links still
> work?" — **Add Redirect** / **Delete Without Redirect** / **Cancel**

Choosing "Add Redirect" opens the Redirects tab pre-filled with `source` set to the
deleted route. When #516 lands full delete/duplicate/undo polish, it reuses this same
offer path rather than rebuilding it.

## 5. Pre-deploy diff scan

A new Swift-side scanner — pure `SiteContentGraph` diffing, no JS/plugin involvement:

- After every successful deploy, write the current route list to
  `Config/last-deployed-routes.json` (app-owned, not git — deploy metadata, not site
  content, matching `Config/`'s existing role for `settings.plist`/`chat-history.jsonl`).
- Before the next deploy, `PreDeployCheck.check` additionally diffs the current
  `SiteContentGraph` routes against that snapshot. Any route that vanished with no
  covering `redirects.json` entry adds a new `ScanWarning` (category
  `.orphanedRoute`) — a **warning, not a blocker**, since a deliberate content removal
  shouldn't be forced into a redirect.
- This merges into the existing `Outcome` / `HealthModel` / `HealthBadgeView`
  pipeline untouched — no new UI surface beyond the existing deploy-readiness badge.

## Testing

- `RedirectsStore`: load/save/validation round-trips (cycle detection, duplicate
  sources, malformed paths).
- Astro integration: a template-level test (in the style of
  `IntegrationTemplateAssetsTests`) verifying `_redirects` output format and the
  dev-config `redirects` wiring.
- Delete flow + dialog trigger: Swift Testing on the new delete service, mirroring
  `NavigatorRenameService`'s test style.
- Route-diff scanner: unit tests feeding synthetic "before/after" `SiteContentGraph`
  snapshots, including the redirect-covers-the-gap case (no warning).

## Non-goals

- Redirect chain resolution (A → B → C).
- Bulk import/export of redirects.
- Historical audit trail of past redirects (git history of `redirects.json` covers
  this implicitly).
- Full delete/duplicate/undo UX polish — that's #516; this only builds the minimal
  delete needed to exercise the redirect-offer path.
