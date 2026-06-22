# Booking `button` placement (#289) — design

**Issue:** #289 — Bucket 3 follow-up: in-page booking 'button' style placement
**Split from:** #282 / PR #287, where booking `style` was reduced to `inline`/`floating` and the `button` variant was deferred.

## Background

`BookingWidget.astro` (`Resources/Template/integrations/components/`) already implements a
complete `button` variant for both providers:

- **Cal.com** — an in-flow `<button data-cal-link>` that triggers `Cal("pop")` (modal popup).
- **Calendly** — an in-flow `<button>` whose click handler calls `Calendly.initPopupWidget`.

Both share the existing `.booking-button` CSS. So the rendering path is done. What is missing
is the **wiring**: the booking descriptor in `Sources/AnglesiteCore/IntegrationCatalog.swift`
exposes only two placement choices and never stages the `button` variant.

Current descriptor placement choices:

- `inline` → `copyFile` a dedicated `src/pages/book.astro` (embedded scheduler).
- `floating` → two `injectAtAnchor` ops into `src/layouts/BaseLayout.astro`
  (import at `// anglesite:imports`, widget at `<!-- anglesite:body-end -->`), site-wide badge.

`BOOKING_STYLE` and `BOOKING_BUTTON_TEXT` are already written by the `.always` `writeConfig` op,
and `addCSPDomains(fromProvider: true)` is `.always`, so provider CSP domains already flow for
every style (consistent with the `public/_headers` work in #290/PR #294 — no overlap).

## Goal

Expose the `button` variant as a third placement choice that injects an in-flow booking CTA
button into the **home page hero**.

## Design

### 1. Template anchors — `Resources/Template/src/pages/index.astro`

The homepage currently has no injection anchors. Add two, matching the `BaseLayout` convention:

- `// anglesite:imports` in the frontmatter (for the component import).
- `<!-- anglesite:hero-cta -->` inside the `.hero` `<section>`, **after** the existing hero
  paragraphs (where the button lands).

These are inert no-op comments in the shipped template; they are only populated when an owner
selects the `button` placement.

### 2. Booking descriptor — `Sources/AnglesiteCore/IntegrationCatalog.swift`

- Add the third `style` choice:
  `Choice(value: "button", label: "Button on the home page")`.
- Change the `buttonText` field's `visibleWhen` so it shows for `floating` **and** `button`
  (see §3).
- Add two `button`-gated operations, mirroring the `floating` pair but targeting `index.astro`:
  - `injectAtAnchor(file: "src/pages/index.astro", anchor: "// anglesite:imports", snippet:
    "import BookingWidget from \"../components/BookingWidget.astro\";\nimport { readConfig } from \"../../scripts/config\";",
    when: .fieldEquals(key: "style", value: "button"), style: .line)`
  - `injectAtAnchor(file: "src/pages/index.astro", anchor: "<!-- anglesite:hero-cta -->",
    snippet: "{readConfig(\"BOOKING_STYLE\") === \"button\" && (<BookingWidget provider={readConfig(\"BOOKING_PROVIDER\")} username={readConfig(\"BOOKING_USERNAME\")} eventSlug={readConfig(\"BOOKING_EVENT_SLUG\")} buttonText={readConfig(\"BOOKING_BUTTON_TEXT\")} style=\"button\" />)}",
    when: .fieldEquals(key: "style", value: "button"), style: .html)`
- `copyFile` (component), `writeConfig`, and `addCSPDomains` are unchanged (already `.always`).

### 3. Condition model change — `Sources/AnglesiteCore/IntegrationDescriptor.swift`

`buttonText` must be visible for `floating` and `button`, but `Condition` only supports
single-value `.fieldEquals`. Add one case:

```swift
case fieldIn(key: String, values: [String])
```

evaluated in the two existing sites:

- `IntegrationPlanner.isVisible` → `case .fieldIn(let key, let values): return values.contains(answers[key] ?? "")`
- `IntegrationCatalog.check` → validate `key` exists in `fieldKeys` (same as `.fieldEquals`).

`buttonText` then uses `visibleWhen: .fieldIn(key: "style", values: ["floating", "button"])`.

*Rejected alternative:* make `buttonText` `visibleWhen: .always` (no model change) — but it would
surface an irrelevant "Button text" field on the `inline` choice. The `.fieldIn` case is small
and reusable, so it wins.

## Testing

- **`IntegrationPlanner`**: `style=button` answers produce exactly the two `index.astro`
  injections + the `.always` ops, and the `inline`/`floating` plans are unaffected (regression
  guard).
- **`Condition.fieldIn` visibility**: `button` and `floating` show `buttonText`; `inline` hides it.
- **`IntegrationCatalog.check`**: still passes with the new `.fieldIn` condition (validates `style`).
- **Template asset guard**: editing `index.astro` will trip the `IntegrationTemplateAssetsTests`
  fixture-completeness checks — run `swift test --filter Integration` and update expected fixtures
  before pushing.

## Scope / non-goals

- No change to `BookingWidget.astro` (the `button` render path already exists).
- No new CSP handling (provider domains already flow via the `.always` `addCSPDomains`).
- No change to `inline`/`floating` behavior.
