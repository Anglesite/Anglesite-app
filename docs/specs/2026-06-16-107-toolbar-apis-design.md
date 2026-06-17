# Adopt macOS 27 toolbar APIs for the SiteWindow action bar (#107)

**Date:** 2026-06-16
**Issue:** [#107](https://github.com/Anglesite/Anglesite-app/issues/107)
**Status:** Design approved, pending implementation plan

## Problem

The `SiteWindow` action bar (Deploy, Backup, Audit, Chat, plus the deploy-readiness
health badge) is currently a hand-rolled `HStack` inside the window *content*
(`SiteWindow.mainPane`, lines 156–231), interleaved with the site name, live
dev-server URL, and an "Open in browser" button.

macOS 27 SwiftUI adds precise toolbar overflow control
([What's new in SwiftUI, WWDC26](https://developer.apple.com/videos/play/wwdc2026/269/)):

- `visibilityPriority` — order which items stay visible as the window narrows.
- `toolbarOverflowMenu` — collapse lower-priority items into an overflow menu
  instead of letting them vanish.
- `topBarPinnedTrailing` — keep critical actions pinned at the trailing edge.

These modifiers apply to native toolbar items (`ToolbarItem` / `ToolbarItemGroup`).
They have **no effect on a plain `HStack`**. So adopting them is not "add three
modifiers" — it requires migrating the action bar to a native `.toolbar`.

The goal: the load-bearing actions — **Deploy above all** — must never silently
disappear when the user narrows the `SiteWindow` alongside the preview pane.

## Decisions

1. **Migrate to a native `.toolbar`** (chosen over hand-rolling overflow with
   `ViewThatFits` + a manual menu). This is the only way the named macOS 27 APIs
   take effect, and it is the issue's stated intent.
2. **Live URL → `.navigationSubtitle`**, shown under the site name in the title
   bar once the dev server is ready. The content header row is removed entirely;
   the preview webview reclaims that vertical space.

## Architecture

Replace the content-header `HStack` in `SiteWindow.mainPane` with a native
`.toolbar { }` on the site UI. The window chrome carries identity:

- `.navigationTitle(site.name)` — already present (line 130). The duplicate
  `Text(site.name).font(.headline)` in the deleted header goes away.
- `.navigationSubtitle(preview.readyURL?.absoluteString ?? "")` — live dev-server
  URL, only meaningful once `readyURL` resolves (empty string until then).

`mainPane` becomes just the `switch preview.state { … }` body (preview /
starting / failed / idle) with no header `HStack` and no leading `Divider`.

### Toolbar item inventory (trailing edge)

| Item | Treatment | Rationale |
|---|---|---|
| **Deploy** | `.primaryAction` + `.visibilityPriority(.high)` | Load-bearing; collapses last |
| **Health badge** | `.visibilityPriority(.high)` | Deploy-readiness must stay visible |
| **Open in browser** | `.automatic` (default), only when `readyURL != nil` | Useful, not critical |
| **Chat** (⌘K) | `.automatic` (default) | Toggled often → kept above Audit/Backup |
| **Audit** | `.low` | Collapses before Chat |
| **Backup** | `ToolbarItemVisibilityPriority(lowerThan: .low)` | First to collapse |

Collapse order as the window narrows (least critical first):
**Backup → Audit → Chat → Open in browser**, all dropped into the **native macOS
toolbar overflow chevron** automatically (there is no `toolbarOverflowMenu` on
macOS — see API-surface reality below). Deploy and the health badge remain
visible.

### Carried-over behavior (unchanged)

- All `.disabled(...)` conditions: `site.isValid`, and the
  `isRunning`-mutual-exclusion across Deploy / Backup / Audit.
- All `.help(...)` tooltips.
- The Chat ⌘K keyboard shortcut. (Verify the shortcut still fires when Chat is
  collapsed into the overflow menu; if SwiftUI drops it, surface the shortcut via
  a `Commands` menu as a backstop.)
- The health badge's popover, its `onRecheck` / `onAskClaude` closures, and the
  `#if ANGLESITE_MAS` gate on "Ask Claude" (which lives *inside* the popover,
  untouched by this change).
- Deploy/Backup drawers, the deploy blocked/token sheets, and the audit sheet —
  all attached to the site UI, unaffected.

## API-surface reality (verified against the macOS 27.0 SDK)

A compile-checked spike against the Xcode 27.0 / macOS 27.0 SDK established that
**two of the three issue-named APIs are iOS/visionOS-only** and do not exist on
macOS:

| Issue named API | macOS reality |
|---|---|
| `visibilityPriority` | ✅ Exists. `.visibilityPriority(_ priority: ToolbarItemVisibilityPriority)` on `ToolbarContent` (the `ToolbarItem`, not the inner `Button`). Constants `.high` / `.automatic` (default) / `.low`, plus relative `init(lowerThan:)` / `init(higherThan:)`. Higher priority = collapses **last**. |
| `toolbarOverflowMenu` | ❌ `@available(macOS, unavailable)`. macOS toolbars overflow **automatically** via the native NSToolbar chevron — there is no SwiftUI knob and none is needed. `visibilityPriority` is the lever that orders which items the native overflow drops first. |
| `topBarPinnedTrailing` | ❌ `@available(macOS, unavailable)`. macOS equivalent for the primary pinned action is `.primaryAction` placement + `.visibilityPriority(.high)`. (A true un-removable pin would additionally need `.defaultCustomization(.visible, .alwaysAvailable)` inside a customizable `.toolbar(id:)` — explicitly out of scope, see Decision below.) |

So the issue's *goal* is fully achievable on macOS — Deploy stays put, secondary
actions collapse into the system overflow — but it is expressed through
`visibilityPriority` + `.primaryAction` + the platform's automatic overflow, not
the two iOS-only symbols. The PR must state this so the issue's acceptance
criteria are read against the macOS-native mechanism. No `if #available` guards
are needed — the deployment target is macOS 27.0 on both targets
(`Package.swift`, `project.yml`).

### Decision: non-customizable `.toolbar { }`

Use a plain `.toolbar { }`, not a customizable `.toolbar(id:)`. Deploy is pinned
via `.primaryAction` + `.visibilityPriority(.high)`; the native chevron handles
overflow. This meets the issue's goal with the least surface area and adds no
user-facing "Customize Toolbar" affordance (which `.toolbar(id:)` +
`defaultCustomization` would introduce — beyond this issue's scope).

## MAS parity

The toolbar is target-agnostic. Chat is on both targets now; the only
`#if ANGLESITE_MAS` gate is the "Ask Claude" button inside the health-badge
popover, which is not part of this migration. "No MAS regression" therefore means
the MAS target builds and lays the toolbar out identically.

## Testing & verification

This is declarative SwiftUI with little unit-testable logic, so verification is
behavioral:

- `xcodebuild` both schemes — `Anglesite` (DevID) and `AnglesiteMAS` — to prove
  the `.app` links, not just `swift test`.
- Manual narrow-width check via the `run` skill: shrink the `SiteWindow`, confirm
  Deploy stays pinned, secondary actions collapse into the overflow menu rather
  than vanishing, and the health badge survives. With the chat pane open (DevID),
  confirm the toolbar still behaves. Capture a narrow-width screenshot for the PR.

## Acceptance criteria (from #107)

- [ ] Deploy remains visible/pinned at all reasonable window widths.
- [ ] Secondary actions collapse into the overflow menu rather than vanishing.
- [ ] No regressions in the MAS target's toolbar layout. (The issue's original
      "chat-less toolbar layout" wording is stale — MAS now has a chat pane via
      the on-device assistant, #159 — but the toolbar is target-agnostic.)

## Out of scope

- The debug pane (a separate menu-opened `Window`, not part of this action bar).
- Any change to the deploy/backup/audit command wiring (#84–#86, already done).
- #94 (reducing the chat panel to open-ended tasks) — independent, still open.
