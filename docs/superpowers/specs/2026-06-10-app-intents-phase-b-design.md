# Phase B — App Intents for Anglesite (#88, #89, #90)

**Status:** Design — approved for planning
**Date:** 2026-06-10
**Issues:** #88 (intents), #89 (SiteEntity), #90 (AppShortcutsProvider)
**Tracking:** macOS 27 platform features; foundation for #101 (system MCP), #102 (Spotlight)

## Goal

Expose Anglesite's deterministic site operations — deploy, backup, audit, open — to
Siri and Shortcuts.app via App Intents, with **no Claude/LLM process involved**. Users
can say "Deploy my portfolio site with Anglesite" or build a Shortcuts automation that
audits then deploys.

The command actors (`DeployCommand`, `BackupCommand`, `AuditCommand`) already do all
orchestration and construct with sensible zero-arg defaults; `SiteStore.shared` already
maintains the site registry (including the per-site security-scoped bookmark). The intents
are thin, deterministic wrappers over those.

## Non-goals

- No new business logic in intents — they wrap existing command actors only.
- No App Intents for chat or any LLM-backed flow (those are `#if !ANGLESITE_MAS` and
  out of scope here).
- No Spotlight entity indexing (#102) or system-wide MCP (#101) — this spec is the
  entity/intent foundation they will build on, not those features.

## Approach

Entity, intents, and the shortcuts provider live in a new **`Sources/AnglesiteApp/Intents/`**
group (the app target — `OpenSiteIntent` needs the app's window scene and the intents run
in the app runtime). One shared **`SiteAccess`** helper lives in `AnglesiteCore` so the
security-scoped wrapping is testable and target-gated in one place.

*Alternatives considered:* (a) intents in `AnglesiteCore` — rejected: `OpenSiteIntent`
needs the app window scene and `AppShortcutsProvider` is app-level; (b) a separate
AppIntents framework target — rejected: unnecessary build complexity for v0.

Both build targets compile the intents (App Intents are auto-discovered from the app
bundle — no `Info.plist` registration needed). MAS-specific behavior is gated with
`#if ANGLESITE_MAS`, consistent with the rest of the codebase.

## Components

### 1. `SiteEntity` + `SiteEntityQuery` (#89)

`struct SiteEntity: AppEntity`:
- `id: String` — the `SiteStore.Site.id` (path-derived, stable across launches).
- `displayName: String`, `siteType: String`, `directory: URL` — surfaced properties.
- `displayRepresentation` → site name + type subtitle; `typeDisplayRepresentation` = "Site".

`SiteEntityQuery: EntityStringQuery`, backed by `SiteStore.shared` (read live every call,
no cache, so it never goes stale):
- `entities(for ids:)` — resolve specific ids.
- `suggestedEntities()` — all registered sites.
- `entities(matching string:)` — case-insensitive substring/fuzzy match on `displayName`
  so Siri resolves "my portfolio site" to the right entity.
- `defaultResult()` — returns the sole site when exactly one exists (no picker prompt for
  single-site users).

### 2. `SiteAccess` helper (`AnglesiteCore`)

A single async wrapper that grants folder access around a unit of work, returning the
closure's value:

```
enum SiteAccess {
    static func withScopedAccess<T>(
        to site: SiteStore.Site,
        in store: SiteStore = .shared,
        _ body: (URL) async -> T
    ) async throws -> T
}
```

- **DevID (non-sandboxed):** pass `site.path` straight to `body` — no security scope needed.
- **MAS (`#if ANGLESITE_MAS`):** look up `store.bookmarkData(for: site.id)` →
  `SecurityScopedBookmark.resolve` → `startAccessingSecurityScopedResource()`; run `body`;
  `defer` `stopAccessingSecurityScopedResource()`. On a stale bookmark, re-mint and persist
  (mirrors `SiteWindow.acquireGrant`). If the site has **no** bookmark, throw
  `SiteAccess.Error.noGrant` carrying a friendly "re-add the folder via Open Folder…"
  message, which the intent surfaces as its result dialog.

This reuses the existing, proven `SecurityScopedBookmark` API. Unlike the window path
(which holds the grant for the window's lifetime), `withScopedAccess` is short-lived and
balanced per command — safe even if a window already holds the same grant (start/stop are
balanced).

### 3. The four intents (#88)

Each declares `@Parameter var site: SiteEntity`, a `parameterSummary`, and returns
`some IntentResult & ProvidesDialog`. The three spawning intents run their command actor
inside `SiteAccess.withScopedAccess`; `noGrant`/actor-failure paths map to a dialog.

- **`DeploySiteIntent`** — calls `requestConfirmation` first
  ("Deploy <site> to production?"), then `DeployCommand.deploy(siteID:siteDirectory:)`.
  Result mapping: `.succeeded(url)` → "Deployed to <url>"; `.blocked(failures, warnings)` →
  "Deploy blocked by the pre-deploy security scan: …" (no override — the scan still gates,
  matching the app rule that the app cannot bypass plugin security hooks);
  `.failed(reason, _)` → the reason.
- **`BackupSiteIntent`** — `BackupCommand.backup(...)`. No confirmation (non-destructive
  git commit/push). `.succeeded(sha, branch, remote)` → "Backed up <sha> to <remote>";
  `.noChanges` → "No changes to back up"; `.failed` → reason.
- **`AuditSiteIntent`** — `AuditCommand.audit(...)`. No confirmation. `.succeeded(report)` →
  finding counts by severity; returns that summary as a value so a downstream intent can
  consume it. `.failed` → reason.
- **`OpenSiteIntent`** — no spawn, works on both targets. `openAppWhenRun = true`; requests
  the app focus/open the `SiteWindow` for `site.id`. **Routing mechanism (router singleton
  vs. `OpenIntent` conformance) is chosen during writing-plans**; the requirement is: from
  the intent, open or focus the existing `WindowGroup(for: String.self)` site window for
  the selected id. Returns a confirmation dialog.

#### Test seam — `CommandFactory`

The three spawning intents depend on a small factory rather than constructing actors
inline, so `Result → dialog` behavior is unit-testable without spawning:

```
protocol CommandFactory: Sendable {
    func deploy() -> DeployCommand
    func backup() -> BackupCommand
    func audit() -> AuditCommand
}
```

Default implementation returns the real zero-arg actors. Tests inject a fake factory whose
actors are built with the existing closure seams (resolver/token/git stubs) to return
canned `Result`s, then assert the intent's dialog.

### 4. `AppShortcutsProvider` + chaining (#90)

`AnglesiteShortcuts: AppShortcutsProvider` registers curated phrases (so they appear in
Spotlight and Siri suggestions):
- "Deploy my site with ${applicationName}"
- "Back up my site with ${applicationName}"
- "Check my site with ${applicationName}"

Audit→deploy chain: `AuditSiteIntent`'s returned value/dialog lets the Shortcuts editor
feed the audited site into `DeploySiteIntent` (which still runs its `requestConfirmation`
gate when chained). The exact chaining surface (`opensIntent` vs. a returned `SiteEntity`
the user pipes into the next action) is finalized during planning; the requirement is that
"audit then deploy" composes in Shortcuts and that scheduled backups run reliably with no
window open (covered by `SiteAccess`).

## Error handling

- **No security-scoped grant (MAS):** `SiteAccess` throws `noGrant`; intent returns a dialog
  telling the user to re-add the folder via Open Folder. No crash, no silent failure.
- **Pre-deploy scan refusal:** surfaced verbatim as the deploy dialog; never overridden.
- **Command actor `.failed`:** the actor's `reason` string becomes the dialog.
- **Site not found / stale id:** `SiteEntityQuery` returns no entity; Shortcuts/Siri report
  the unresolved parameter through the system UI.

## Testing

- **Unit (new `Tests/.../IntentsTests` or in `AnglesiteCoreTests`):**
  - `SiteAccess` DevID pass-through (the MAS branch is compile-gated; covered by manual
    smoke since it needs a real sandboxed signed run).
  - Each intent's `Result → dialog` mapping via a fake `CommandFactory`.
  - `SiteEntityQuery` resolution: `entities(for:)`, `entities(matching:)` fuzzy match,
    `defaultResult()` single-site auto-select — against a `SiteStore` seeded with fixtures.
- **Manual smoke (documented, like the existing MAS smoke tasks):**
  - Intents discoverable in Shortcuts.app on both targets.
  - Siri voice invocation of each phrase.
  - "Audit then deploy" Shortcuts automation.
  - Scheduled background backup on MAS (exercises headless `SiteAccess` bookmark path).

## Target gating

- All intents, `SiteEntity`, `SiteEntityQuery`, `AnglesiteShortcuts`, `SiteAccess`,
  `CommandFactory`, and the window router compile into **both** `Anglesite` (DevID) and
  `AnglesiteMAS`.
- Only the `SiteAccess` MAS branch and (if used) any MAS-specific routing detail sit behind
  `#if ANGLESITE_MAS`.
- No chat/LLM/update-framework coupling — nothing here is excluded from MAS.

## Acceptance criteria (rolled up from #88/#89/#90)

- [ ] `SiteEntity` is an `AppEntity` with a working `EntityStringQuery`; fuzzy name
      resolution; single-site auto-select; stays in sync with `SiteStore`.
- [ ] Four intents discoverable in Shortcuts.app; Siri can invoke each by voice.
- [ ] Intents use the deterministic command actors — no Claude process spawned.
- [ ] `DeploySiteIntent` confirms before deploying; pre-deploy scan still gates.
- [ ] Each intent returns a meaningful result dialog.
- [ ] `AppShortcutsProvider` registered with curated phrases appearing in Spotlight/Siri.
- [ ] "Audit then deploy" workflow composes; scheduled backup runs reliably (incl. MAS
      headless via `SiteAccess`).
- [ ] Builds clean and works on both `Anglesite` and `AnglesiteMAS` targets.

## Build sequence (for the plan)

1. `SiteAccess` helper + tests (DevID branch).
2. `SiteEntity` + `SiteEntityQuery` + tests.
3. `CommandFactory` + the four intents + `Result→dialog` tests.
4. `OpenSiteIntent` window routing (mechanism decided here).
5. `AnglesiteShortcuts` provider + chaining.
6. Wire both targets; manual smoke pass; update `docs/build-plan.md` Phase B status.
